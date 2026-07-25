#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

require_text() {
    local file="$1"
    local text="$2"
    if ! grep -Fq "$text" "$file"; then
        echo "missing '$text' in $file" >&2
        exit 1
    fi
}

require_text Makefile "YTABLabUI.m"
require_text Settings.x "YTABLabDashboardViewController"
require_text YTABLabUI.h "YTABLabRuntimeProviding"
require_text YTABLabUI.m "Unknown / Needs Research"
require_text YTABLabUI.m "Raw Lab"
require_text YTABLabUI.m "Modified"
require_text YTABLabUI.m "UISearchController"
require_text YTABLabUI.m "Reset"
require_text YTABLabUI.m "Raw selector"
require_text YTABLabUI.m "Source class"
require_text YTABLabUI.m "Native value"
require_text YTABLabUI.m "Effective value"

if grep -Fq "No verified description is available" YTABLabUI.m; then
    echo "polished UI static checks passed"
else
    echo "truthful unknown-description fallback is missing" >&2
    exit 1
fi
