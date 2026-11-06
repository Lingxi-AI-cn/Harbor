#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p checks
BUILD_LOG=$(mktemp -t harbor-package)
trap 'rm -f "$BUILD_LOG"' EXIT
export BUILD_LOG
bash scripts/build-desktop-engine.sh > checks/embedded-helper-build.log 2>&1
cargo build --offline --release --features ghostty --message-format=json > "$BUILD_LOG"
python3 scripts/verify-ghostty.py --library
python3 scripts/package-ghostty.py
