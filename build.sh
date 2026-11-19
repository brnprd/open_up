#!/bin/bash
# Builds build/OPEN_UP.app (helper binary + bundled UI + icon), ad-hoc signed.
# Set UNIVERSAL=1 to build for both Apple silicon and Intel (used by package.sh).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/OPEN_UP.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "${UNIVERSAL:-}" == "1" ]]; then
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos12.0" helper/main.swift -o "build/OpenUp-$arch"
  done
  lipo -create build/OpenUp-arm64 build/OpenUp-x86_64 -output "$APP/Contents/MacOS/OpenUp"
  rm build/OpenUp-*
else
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" helper/main.swift -o "$APP/Contents/MacOS/OpenUp"
fi

cp helper/Info.plist "$APP/Contents/Info.plist"
cp -R ui "$APP/Contents/Resources/ui"

swift helper/make_icon.swift build/AppIcon.iconset >/dev/null
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "> built $APP"
