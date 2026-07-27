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
require_text README.md "# YTABConfig Feature Lab"
require_text README.md "Original YTABConfig by PoomSmart."
require_text README.md "[GNU General Public License v3.0](LICENSE)."
require_text "layout/Library/Application Support/YTABC.bundle/en.lproj/Localizable.strings" '"OPEN_MEGATHREAD" = "Original project discussions";'

rootless_scheme_count="$(grep -Fc 'export THEOS_PACKAGE_SCHEME=rootless' build.sh)"
if [[ "$rootless_scheme_count" -ne 2 ]]; then
    echo "both deb and standalone sideload builds must use the rootless Mach-O scheme" >&2
    exit 1
fi

if test -e docs/superpowers/plans/2026-07-25-catalog-export.md || test -e docs/superpowers/specs/2026-07-25-catalog-export-design.md; then
    echo "verbose superpowers planning documents must not ship" >&2
    exit 1
fi

echo "package metadata static checks passed"
