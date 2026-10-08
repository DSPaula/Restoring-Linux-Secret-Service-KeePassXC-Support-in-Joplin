#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 INPUT_APP_ASAR OUTPUT_APP_ASAR"
    exit 1
fi

INPUT_ASAR=$1
OUTPUT_ASAR=$2

if [[ ! -f "$INPUT_ASAR" ]]; then
    echo "ERROR: input ASAR not found: $INPUT_ASAR" >&2
    exit 1
fi

command -v node >/dev/null || { echo "ERROR: node is required" >&2; exit 1; }
command -v npx >/dev/null || { echo "ERROR: npx is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 1; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

EXTRACTED="$WORKDIR/extracted"
mkdir -p "$EXTRACTED"

echo "Extracting: $INPUT_ASAR"
npx --yes @electron/asar extract "$INPUT_ASAR" "$EXTRACTED"

python3 - "$EXTRACTED" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

files = [
    root / "main.bundle.js",
    root / "main-html.bundle.js",
]

def replace_exact(path, old, new, label):
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"ERROR: {label}: expected exactly 1 occurrence in {path.name}, found {count}"
        )
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"OK {path.name}: {label}")

for path in files:
    if not path.is_file():
        raise SystemExit(f"ERROR: bundle not found: {path}")

    replace_exact(
        path,
        ".keytar:null",
        ".keytar:require('keytar')",
        "enable bundled node-keytar",
    )

    replace_exact(
        path,
        "return!!(",
        "return!1&&!!(",
        "disable SafeStorage capability path",
    )

    replace_exact(
        path,
        '"featureFlag.linuxKeychain":{value:!1,',
        '"featureFlag.linuxKeychain":{value:!0,',
        "enable Linux keychain feature flag",
    )
PY

echo "Checking JavaScript syntax..."
node --check "$EXTRACTED/main.bundle.js"
node --check "$EXTRACTED/main-html.bundle.js"
echo "Syntax OK"

rm -f "$OUTPUT_ASAR"
mkdir -p "$(dirname "$OUTPUT_ASAR")"

echo "Packing: $OUTPUT_ASAR"
npx --yes @electron/asar pack "$EXTRACTED" "$OUTPUT_ASAR"

echo "Comparing ASAR file counts..."
ORIGINAL_COUNT=$(npx --yes @electron/asar list "$INPUT_ASAR" | wc -l)
PATCHED_COUNT=$(npx --yes @electron/asar list "$OUTPUT_ASAR" | wc -l)
echo "Original files: $ORIGINAL_COUNT"
echo "Patched files:  $PATCHED_COUNT"

if [[ "$ORIGINAL_COUNT" -ne "$PATCHED_COUNT" ]]; then
    echo "ERROR: ASAR file count changed" >&2
    exit 1
fi

echo "ASAR_FILE_COUNT_OK"

echo "PATCH_APPLIED"
echo "Output: $OUTPUT_ASAR"
sha256sum "$OUTPUT_ASAR"
