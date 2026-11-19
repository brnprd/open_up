#!/bin/bash
# Builds OPEN_UP and installs it to ~/Applications.
#   ./install.sh                   build + install
#   ./install.sh --default md pdf  ...also make OPEN_UP the double-click app for those types
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/OPEN_UP.app"
./build.sh

pkill -f "OPEN_UP.app/Contents/MacOS/OpenUp" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$APP" && cp -R build/OPEN_UP.app "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "> installed $APP"

# One-time move of rules from the old Docker version.
STATE="$HOME/Library/Application Support/OPEN_UP/state.json"
if [[ -f data/state.json && ! -f "$STATE" ]]; then
  mkdir -p "$(dirname "$STATE")" && cp data/state.json "$STATE"
  echo "> moved your rules from data/state.json"
fi

if [[ "${1:-}" == "--default" ]]; then
  shift
  "$APP/Contents/MacOS/OpenUp" --set-default "$@"
fi

echo "done. settings: open \"$APP\"   ·   picker: ./bin/openup somefile.pdf"
