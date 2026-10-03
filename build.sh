#!/bin/sh
# Build the macOS version: mac/main.m -> bin/Blackout.app
#
# Needs only the Xcode Command Line Tools (xcode-select --install).
# Produces a universal binary (Apple Silicon + Intel) and signs it ad hoc,
# which Apple Silicon requires before it will run anything.

set -eu
cd "$(dirname "$0")"

VERSION=$(sed -n 's/^#define BLACKOUT_VERSION_STR "\(.*\)".*/\1/p' src/version.h | tr -d '\r')
if [ -z "$VERSION" ]; then
    echo "[ERROR] BLACKOUT_VERSION_STR not found in src/version.h"
    exit 1
fi

APP=bin/Blackout.app

if [ ! -f assets/blackout.icns ]; then
    if command -v python3 >/dev/null 2>&1; then
        python3 tools/make_icon.py --icns
    else
        echo "[WARN] assets/blackout.icns missing and python3 unavailable - building without icon"
    fi
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -std=gnu11 -fobjc-arc -Os -Wall -Wextra \
    -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
    -framework Cocoa -framework Carbon -framework ServiceManagement \
    -Wl,-dead_strip \
    -o "$APP/Contents/MacOS/Blackout" mac/main.m
strip -x "$APP/Contents/MacOS/Blackout"

sed "s/@VERSION@/$VERSION/g" mac/Info.plist > "$APP/Contents/Info.plist"
[ -f assets/blackout.icns ] && cp assets/blackout.icns "$APP/Contents/Resources/"
# The checkout may have CRLF here (.gitattributes); the app normalises anyway.
tr -d '\r' < installer/first-run-todo.txt > "$APP/Contents/Resources/first-run-todo.txt"

codesign --force --sign - "$APP"

BIN_BYTES=$(stat -f%z "$APP/Contents/MacOS/Blackout")
APP_KB=$(du -sk "$APP" | cut -f1)
echo
echo "[OK] $(pwd)/$APP - Blackout $VERSION, binary $BIN_BYTES bytes, bundle $APP_KB KB"
