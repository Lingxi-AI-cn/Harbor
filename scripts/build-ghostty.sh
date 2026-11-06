#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ZIG:=$(command -v zig || true)}"
EXPECTED_ZIG=$(python3 -c 'import json; print(json.load(open("vendor/ghostty.lock.json"))["zig"])')
if [[ -z "$ZIG" ]]; then
  echo "Set ZIG to an existing Zig $EXPECTED_ZIG executable. No compiler is installed by this script." >&2
  exit 1
fi
[[ "$($ZIG version)" == "$EXPECTED_ZIG" ]] || { echo "Ghostty requires Zig $EXPECTED_ZIG" >&2; exit 1; }
python3 scripts/verify-ghostty.py
cd vendor/ghostty
"$ZIG" build --cache-dir "$PWD/.zig-cache-harbor" -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native -Demit-themes=false -Demit-docs=false
cd ../..
python3 scripts/record-ghostty-build.py
