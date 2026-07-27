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

	rm -rf "${PACKAGES_DIR}/${APP_NAME}.dylib" "$BUNDLE_OUTPUT"
	cp "$dylib" "${PACKAGES_DIR}/${APP_NAME}.dylib"
	cp -R "$BUNDLE_SOURCE" "$BUNDLE_OUTPUT"

	rm -f "${PACKAGES_DIR}/${APP_NAME}-sideload.zip"
	(
		cd "$PACKAGES_DIR"
		zip -qry "${APP_NAME}-sideload.zip" "${APP_NAME}.dylib" "$BUNDLE_NAME"
	)

	log "Dylib: ${PACKAGES_DIR}/${APP_NAME}.dylib"
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
	echo "  dylib          Build YTABConfig.dylib, YTABC.bundle, and a sideload ZIP"
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
