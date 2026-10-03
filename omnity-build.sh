#!/bin/sh
# Omnity: build the macOS app and brand it, producing zig-out/Omnity.app.
#
# Xcode always derives CFBundleName (the menu bar name) from PRODUCT_NAME,
# and renaming the product would rename the Swift module and the zig build
# paths. So the name is set here, after the build, and the app re-signed.
set -eu
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:$PATH"

zig build -Doptimize=ReleaseFast

rm -rf zig-out/Omnity.app
cp -R zig-out/Ghostty.app zig-out/Omnity.app
/usr/libexec/PlistBuddy -c "Set :CFBundleName Omnity" zig-out/Omnity.app/Contents/Info.plist
codesign --force --deep --sign - zig-out/Omnity.app
codesign --verify zig-out/Omnity.app
echo "Built zig-out/Omnity.app"
