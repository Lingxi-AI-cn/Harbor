#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
REV=$(git -C vendor/freerdp rev-parse HEAD)
[[ "$REV" == 5a10d7b6b79a2fbc62e8eba77085cd356dc303a6 ]]
git -C vendor/freerdp diff --exit-code --quiet
cmake -S vendor/freerdp -B vendor/freerdp-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
 -DWITH_CLIENT=ON -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT_SDL=OFF -DWITH_SDL=OFF -DWITH_CLIENT_MAC=OFF \
 -DWITH_SERVER=ON -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF \
 -DWITH_CUPS=OFF -DWITH_PCSC=OFF -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_MANPAGES=OFF -DWITH_SAMPLE=ON \
 -DWITH_SHADOW=OFF -DBUILD_TESTING=OFF -DWITH_KRB5=OFF -DWITH_AAD=OFF -DWITH_FUSE=OFF -DWITH_WEBVIEW=OFF \
 -DWITH_OPUS=OFF -DWITH_PROXY=OFF -DWITH_JSON_DISABLED=ON -DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@3
cmake --build vendor/freerdp-build -j 8
INSTALL_STAGE=$(mktemp -d "$ROOT/vendor/.freerdp-install.XXXXXX")
trap 'rm -rf "$INSTALL_STAGE"' EXIT
DESTDIR="$INSTALL_STAGE" cmake --install vendor/freerdp-build
# This directory contains only artifacts produced by this script.
rm -rf "$ROOT/vendor/freerdp-install"
mv "$INSTALL_STAGE/usr/local" "$ROOT/vendor/freerdp-install"
mkdir -p vendor/desktop-engine
export PKG_CONFIG_PATH="$ROOT/vendor/freerdp-install/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig"
xcrun clang -Wl,-headerpad_max_install_names -O2 -Wno-deprecated-declarations app/desktop-engine/main.c $(pkg-config --cflags --libs freerdp-client3 freerdp3 winpr3 openssl) -Wl,-rpath,"$ROOT/vendor/freerdp-install/lib" -o vendor/desktop-engine/harbor-desktop-engine
