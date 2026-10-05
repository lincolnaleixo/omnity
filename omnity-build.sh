#!/bin/sh
# Omnity: build the macOS app and brand it, producing zig-out/Omnity.app.
#
# Xcode always derives CFBundleName (the menu bar name) from PRODUCT_NAME,
# and renaming the product would rename the Swift module and the zig build
# paths. So the name is set here, after the build, and the app re-signed.
set -eu
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:$PATH"

# The library from zig, the app from an Xcode scheme build: `zig build`
# builds the app with `xcodebuild -target`, which does not build Swift
# packages from source (WhisperKit).
zig build -Doptimize=ReleaseFast -Demit-macos-app=false
(
    cd macos
    env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        /usr/bin/xcodebuild -scheme Ghostty -configuration ReleaseLocal -arch arm64 \
        SYMROOT="$PWD/build" build
)

rm -rf zig-out/Omnity.app
cp -R macos/build/ReleaseLocal/Ghostty.app zig-out/Omnity.app
/usr/libexec/PlistBuddy -c "Set :CFBundleName Omnity" zig-out/Omnity.app/Contents/Info.plist
codesign --force --deep --sign - zig-out/Omnity.app
codesign --verify zig-out/Omnity.app
echo "Built zig-out/Omnity.app"
