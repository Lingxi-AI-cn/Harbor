#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
OUT="${HARBOR_TEST_OUTPUT:-$PWD/checks/ghostty-backend}"
mkdir -p "$OUT"
ROOT="$PWD/vendor/ghostty"
LIB="${GHOSTTY_TEST_LIBRARY:-$(find "$ROOT/macos/GhosttyKit.xcframework" -name '*.a' -print -quit)}"
xcrun swiftc -O -D GHOSTTY -import-objc-header "$ROOT/include/ghostty.h" app/Localization.swift app/LocalizationCatalog.swift app/TerminalMacroEvent.swift app/TerminalPreferences.swift app/GhosttyRuntime.swift app/GhosttyTerminal.swift app/tests/ghostty/ExtendedChecks.swift app/tests/ghostty/main.swift "$LIB" -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework CoreText -framework CoreGraphics -framework Carbon -framework IOKit -lc++ -o "$OUT/native-test"
if [[ "${HARBOR_TEST_BUILD_ONLY:-0}" == 1 ]]; then exit 0; fi
GHOSTTY_RESOURCES_DIR="$ROOT/zig-out/share/ghostty" exec "$OUT/native-test" "$OUT"
