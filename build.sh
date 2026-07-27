#!/usr/bin/env bash

set -euo pipefail

# Match the RyukGram CI environment: prefer Homebrew GNU Make 4.x.
if [ -d /opt/homebrew/opt/make/libexec/gnubin ]; then
	PATH="/opt/homebrew/opt/make/libexec/gnubin:$PATH"
fi

APP_NAME="YTABConfig"
PACKAGES_DIR="packages"
TWEAK_DYLIB=".theos/obj/${APP_NAME}.dylib"
BUNDLE_SOURCE="layout/Library/Application Support/YTABC.bundle"
BUNDLE_NAME="YTABC.bundle"
BUNDLE_OUTPUT="${PACKAGES_DIR}/${BUNDLE_NAME}"
SIDELOAD_STAGE="${PACKAGES_DIR}/sideload"
SIDELOAD_ROOT_ID="@executable_path/${APP_NAME}.dylib"
SIDELOAD_FRAMEWORKS_ID="@executable_path/Frameworks/${APP_NAME}.dylib"

log() {
	printf '%s\n' "$*"
}

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

ensure_theos() {
	if [ -n "${THEOS:-}" ]; then
		return
	fi

	if [ -d "$HOME/theos" ]; then
		export THEOS="$HOME/theos"
	else
		die "THEOS is not set and ~/theos was not found."
	fi
}

ensure_packages_dir() {
	mkdir -p "$PACKAGES_DIR"
}

clean_build() {
	make clean 2>/dev/null || true
	rm -rf .theos
}

resolve_tweak_dylib() {
	if [ -f "$TWEAK_DYLIB" ]; then
		printf '%s\n' "$TWEAK_DYLIB"
		return
	fi

	find .theos/obj -type f -name "${APP_NAME}.dylib" -print -quit
}

make_final() {
	make FINALPACKAGE=1 "$@"
}

prepare_sideload_dylib() {
	local source="$1"
	local destination="$2"
	local install_id="$3"

	command -v install_name_tool >/dev/null 2>&1 ||
		die "install_name_tool is required for sideload packaging."
	command -v ldid >/dev/null 2>&1 ||
		die "ldid is required for sideload packaging."

	mkdir -p "$(dirname "$destination")"
	cp "$source" "$destination"
	install_name_tool -id "$install_id" "$destination"

	# install_name_tool invalidates the existing ad-hoc signature.
	ldid -S "$destination"
}

build_dylib() {
	local option="${1:-}"
	local dylib

	if [ "$option" != "--fast" ]; then
		clean_build
	fi

	ensure_packages_dir
	log "Building ${APP_NAME}.dylib for Feather/manual sideload injection"
	export THEOS_PACKAGE_SCHEME=rootless
	make_final

	dylib="$(resolve_tweak_dylib)"
	[ -n "$dylib" ] && [ -f "$dylib" ] || die "${APP_NAME}.dylib was not produced."

	rm -rf \
		"${PACKAGES_DIR}/${APP_NAME}.dylib" \
		"${PACKAGES_DIR}/${APP_NAME}-injector.dylib" \
		"$BUNDLE_OUTPUT" \
		"$SIDELOAD_STAGE"

	# Standalone injectors commonly copy a selected dylib to YouTube.app/.
	prepare_sideload_dylib \
		"$dylib" \
		"${PACKAGES_DIR}/${APP_NAME}-injector.dylib" \
		"$SIDELOAD_ROOT_ID"

	# The layout ZIP is deterministic: unpack it into YouTube.app/. Its explicit
	# install name matches the physical Frameworks/ location.
	prepare_sideload_dylib \
		"$dylib" \
		"${SIDELOAD_STAGE}/Frameworks/${APP_NAME}.dylib" \
		"$SIDELOAD_FRAMEWORKS_ID"

	cp -R "$BUNDLE_SOURCE" "$BUNDLE_OUTPUT"
	cp -R "$BUNDLE_SOURCE" "${SIDELOAD_STAGE}/${BUNDLE_NAME}"

	rm -f "${PACKAGES_DIR}/${APP_NAME}-sideload.zip"
	(
		cd "$SIDELOAD_STAGE"
		zip -qry "../${APP_NAME}-sideload.zip" Frameworks "$BUNDLE_NAME"
	)

	log "Injector dylib: ${PACKAGES_DIR}/${APP_NAME}-injector.dylib"
	log "Frameworks dylib: ${SIDELOAD_STAGE}/Frameworks/${APP_NAME}.dylib"
	log "Bundle: ${BUNDLE_OUTPUT}"
	log "Sideload bundle: ${PACKAGES_DIR}/${APP_NAME}-sideload.zip"
}

build_rootless() {
	local base_deb
	local rootless_deb

	clean_build
	ensure_packages_dir

	log "Building ${APP_NAME} rootless deb"
	export THEOS_PACKAGE_SCHEME=rootless
	make_final package

	(
		cd "$PACKAGES_DIR"
		base_deb="$(ls -t *.deb 2>/dev/null | head -n1)"
		[ -n "$base_deb" ] || die "No deb package was produced."

		case "$base_deb" in
			*-rootless.deb)
				rootless_deb="$base_deb"
				;;
			*)
				rootless_deb="${base_deb%.deb}-rootless.deb"
				mv "$base_deb" "$rootless_deb"
				;;
		esac

		printf 'Rootless deb: %s/%s\n' "$PACKAGES_DIR" "$rootless_deb"
	)
}

usage() {
	echo "Usage: $0 <dylib|rootless> [--fast]"
	echo
	echo "  dylib          Build injector dylib, Frameworks layout ZIP, and YTABC.bundle"
	echo "  dylib --fast   Build the dylib without cleaning first"
	echo "  rootless       Build a rootless deb"
	exit 1
}

main() {
	ensure_theos

	case "${1:-}" in
		dylib)
			build_dylib "${2:-}"
			;;
		rootless)
			build_rootless
			;;
		*)
			usage
			;;
	esac
}

main "$@"
