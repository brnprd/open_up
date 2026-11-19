#!/bin/bash
# Builds the OPEN_UP Mac helper, installs it to ~/Applications, and starts the Docker server.
#   ./install.sh                 build + install + start server
#   ./install.sh --default md pdf  ...also make OPEN_UP the double-click app for those types
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/OPEN_UP.app"
BUILD="build/OPEN_UP.app"

echo "> building helper"
rm -rf build && mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" \
  helper/main.swift -o "$BUILD/Contents/MacOS/OpenUp"
cp helper/Info.plist "$BUILD/Contents/Info.plist"

echo "> drawing icon"
swift helper/make_icon.swift build/AppIcon.iconset >/dev/null
iconutil -c icns build/AppIcon.iconset -o "$BUILD/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$BUILD" >/dev/null 2>&1

echo "> installing to $APP"
mkdir -p "$HOME/Applications"
rm -rf "$APP" && cp -R "$BUILD" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "> starting server (docker compose)"
docker compose up -d --build

if [[ "${1:-}" == "--default" ]]; then
  shift
  "$APP/Contents/MacOS/OpenUp" --set-default "$@"
fi

echo
echo "done. open the settings:   open \"$APP\""
echo "     open a file via it:   ./bin/openup somefile.pdf"
