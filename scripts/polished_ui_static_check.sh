#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

require_text() {
    local file="$1"
    local text="$2"
    if ! grep -Fq -- "$text" "$file"; then
        echo "missing '$text' in $file" >&2
        exit 1
    fi
}

reject_text() {
    local file="$1"
    local text="$2"
    if grep -Fq -- "$text" "$file"; then
        echo "unexpected '$text' in $file" >&2
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
require_text YTABLabUI.h "- (BOOL)setOverrideValue:(BOOL)value forFlag:(YTABLabFlag *)flag;"
require_text YTABLabUI.h "- (BOOL)resetOverrideForFlag:(YTABLabFlag *)flag;"
require_text YTABLabUI.h "- (BOOL)resetAllOverrides;"
require_text YTABLabUI.h "hasEffectiveValue"
require_text YTABLabUI.m "NSMutableDictionary<NSString *, NSNumber *> *pendingValues"
require_text YTABLabUI.m "if ([self setOverrideValue:value forFlag:flag]) imported++;"
require_text YTABLabUI.m "UITableViewAutomaticDimension"
require_text YTABLabUI.m "accessibilityLabel"
require_text YTABLabUI.m "accessibilityHint"
require_text YTABLabUI.m "refreshedFlagMatchingFlag"
require_text YTABLabUI.m "Override Recovery"
require_text YTABLabUI.m "Uncatalogued · Removed"
require_text YTABLabUI.m "No override changes were applied."
require_text YTABLabUI.m "Removes the stored override for the removed selector"
reject_text YTABLabUI.m "Needs Review · New · Removed"
reject_text YTABLabUI.m "\"Presets\""
reject_text YTABLabUI.m "No recognized runtime overrides were found."

if grep -Fq "No verified description is available" YTABLabUI.m; then
    echo "polished UI static checks passed"
else
    echo "truthful unknown-description fallback is missing" >&2
    exit 1
fi
