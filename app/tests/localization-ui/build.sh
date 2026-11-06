#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
OUT="$PWD/checks/i18n/native"
mkdir -p "$OUT"
sed '/^@main$/d' app/Harbor.swift > "$OUT/Harbor.swift"
ROOT="$PWD/vendor/ghostty"
LIB="$ROOT/macos/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a"
xcrun swiftc -O -D GHOSTTY -import-objc-header "$ROOT/include/ghostty.h" app/Localization.swift app/LocalizationCatalog.swift app/TerminalMacroEvent.swift app/TerminalPreferences.swift app/Mechanics.swift app/Terminal.swift app/TerminalHost.swift app/TerminalPaneLayout.swift app/WorkspaceState.swift app/SessionManagement.swift app/Productivity.swift app/SerialTransport.swift app/SerialUI.swift app/DesktopSessions.swift app/EmbeddedDesktop.swift app/GhosttyRuntime.swift app/GhosttyTerminal.swift app/TransferOperation.swift app/RemoteFiles.swift app/RemoteFileWorkflows.swift "$OUT/Harbor.swift" app/tests/localization-ui/main.swift "$LIB" -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework CoreText -framework CoreGraphics -framework Carbon -framework IOKit -lc++ -o "$OUT/native-test"
