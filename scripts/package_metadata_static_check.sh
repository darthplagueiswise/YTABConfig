#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

require_text() {
    local file="$1"
    local text="$2"
    if ! grep -Fqx "$text" "$file"; then
        echo "missing '$text' in $file" >&2
        exit 1
    fi
}

require_text control "Package: com.ps.ytabconfig"
require_text control "Name: YTABConfig Feature Lab"
require_text control "Version: 2.0.0"
require_text control "Maintainer: Afterglow Labs"
require_text control "Homepage: https://github.com/afterglow-labs/YTABConfig"
require_text Makefile "PACKAGE_VERSION = 2.0.0"
require_text build.sh '	export THEOS_PACKAGE_SCHEME=rootless'
require_text build.sh 'SIDELOAD_ROOT_ID="@executable_path/${APP_NAME}.dylib"'
require_text build.sh 'SIDELOAD_FRAMEWORKS_ID="@executable_path/Frameworks/${APP_NAME}.dylib"'
require_text README.md "# YTABConfig Feature Lab"
require_text README.md "Original YTABConfig by PoomSmart."
require_text README.md "[GNU General Public License v3.0](LICENSE)."
require_text "layout/Library/Application Support/YTABC.bundle/en.lproj/Localizable.strings" '"OPEN_MEGATHREAD" = "Original project discussions";'

rootless_scheme_count="$(grep -Fc 'export THEOS_PACKAGE_SCHEME=rootless' build.sh)"
if [[ "$rootless_scheme_count" -ne 3 ]]; then
    echo "rootless, standalone, and Feather builds must use the rootless Mach-O scheme" >&2
    exit 1
fi

for sideload_contract in \
    'install_name_tool -id "$install_id" "$destination"' \
    '"${SIDELOAD_STAGE}/Frameworks/${APP_NAME}.dylib"' \
    'zip -qry "../${APP_NAME}-sideload.zip" Frameworks "$BUNDLE_NAME"'; do
    if ! grep -Fq "$sideload_contract" build.sh; then
        echo "missing sideload layout contract '$sideload_contract' in build.sh" >&2
        exit 1
    fi
done

for feather_contract in \
    'build_feather() {' \
    'dpkg-deb -R "$base_deb" "$stage"' \
    '"$SIDELOAD_FRAMEWORKS_ID"' \
    'dpkg-deb -Zxz -z9 -b "$stage" "$feather_deb"' \
    'feather        Build an xz deb for Feather at @executable_path/Frameworks'; do
    if ! grep -Fq "$feather_contract" build.sh; then
        echo "missing Feather deb contract '$feather_contract' in build.sh" >&2
        exit 1
    fi
done

if ! grep -Fq '"youtubeVersion": "21.30.5"' \
    "layout/Library/Application Support/YTABC.bundle/YTABCatalog-v1.json"; then
    echo "embedded catalog must target YouTube 21.30.5" >&2
    exit 1
fi

if [[ -e catalog/curated/youtube-21.28.3.json ]] ||
   [[ ! -e catalog/curated/youtube-21.30.5.json ]]; then
    echo "the reviewed catalog seed must be replaced with YouTube 21.30.5" >&2
    exit 1
fi

if grep -Fq 'zip -qry "${APP_NAME}-sideload.zip" "${APP_NAME}.dylib"' build.sh; then
    echo "sideload ZIP must not place an @rpath dylib at the app root" >&2
    exit 1
fi

if test -e docs/superpowers/plans/2026-07-25-catalog-export.md || test -e docs/superpowers/specs/2026-07-25-catalog-export-design.md; then
    echo "verbose superpowers planning documents must not ship" >&2
    exit 1
fi

echo "package metadata static checks passed"
