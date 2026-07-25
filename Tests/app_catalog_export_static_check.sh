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

require_regex() {
    local file="$1"
    local pattern="$2"
    if ! grep -Eq -- "$pattern" "$file"; then
        echo "missing pattern '$pattern' in $file" >&2
        exit 1
    fi
}

require_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "missing required file $file" >&2
        exit 1
    fi
}

asset="layout/Library/Application Support/YTABC.bundle/YTABCatalog-v1.json"

require_file YTABCatalogProvider.h
require_file YTABCatalogProvider.m
require_file "$asset"

require_text Makefile "YTABCatalogProvider.m"
require_text YTABCatalogProvider.h "YTABLabCatalogProviding"
require_text YTABCatalogProvider.m "schemaVersion"
require_text YTABCatalogProvider.m "youtubeVersion"
require_text YTABCatalogProvider.m "verifiedVersions"
require_text YTABCatalogProvider.m "YTABLabMetadataDocumentedKey"
require_text Settings.x "[[YTABCatalogProvider alloc]"
require_text Settings.x "initWithCatalog:catalog"

require_text YTABLabUI.h "writeJSONExportWithCompletion:"
require_text YTABLabUI.m "NSJSONSerialization"
require_text YTABLabUI.m "dispatch_get_global_queue"
require_text YTABLabUI.m "UIActivityViewController"
require_text YTABLabUI.m "pathExtension"
require_text YTABLabUI.m "- (NSString *)exportText"
require_text YTABLabUI.m "native"
require_text YTABLabUI.m "override"
require_text YTABLabUI.m "effective"
require_text YTABLabUI.m "schemaVersion"
require_text YTABLabUI.m "tweakVersion"
require_text YTABLabUI.m "youtubeVersion"
require_text YTABLabUI.m "exportedAt"
require_text YTABLabUI.m "context"

require_text YTABLabUI.m "extern BOOL YTABResetRuntimeOverride"
require_text YTABLabUI.m "extern BOOL YTABResetAllRuntimeOverrides"
require_text YTABLabUI.m "return YTABResetRuntimeOverride"
require_text YTABLabUI.m "return YTABResetAllRuntimeOverrides"
require_regex Settings.x '^BOOL YTABResetAllRuntimeOverrides\('
require_text Settings.x 'hasPrefix:@"YTABC."'

jq -e '
    .schemaVersion == 1 and
    (.youtubeVersion | type == "string" and length > 0) and
    (.records | type == "array") and
    all(.records[];
        (.class | type == "string" and length > 0) and
        (.selector | type == "string" and length > 0) and
        ((.status // "Unknown") | IN("Verified", "Inferred", "Unknown"))
    )
' "$asset" >/dev/null

echo "app catalog/export static checks passed"
