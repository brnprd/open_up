#!/bin/bash
# Packages OPEN_UP as a drag-to-install disk image: dist/OPEN_UP-<version>.dmg
# Universal (Apple silicon + Intel), ad-hoc signed (not notarized).
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=1 ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" helper/Info.plist)
STAGE="build/dmg"
DMG="dist/OPEN_UP-$VERSION.dmg"

rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R build/OPEN_UP.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME.txt" <<'EOF'
OPEN_UP — a Spotlight-style "open with…" picker.

1. Drag OPEN_UP into Applications.
2. Open it. The first time, macOS may say it can't check the app:
   right-click OPEN_UP → Open → Open (or System Settings → Privacy & Security → Open Anyway).
3. In OPEN_UP's settings, add a file type and press
   "MAKE OPEN_UP DEFAULT FOR …". Double-clicking those files now shows the picker.

Keys: ↑↓ move · ⏎ open · ⇧⏎ always use · ⇥ other apps · type to search · esc / click away to close.
Undo a default: Finder → Get Info → Open with → choose an app → Change All.
EOF

rm -f "$DMG"
hdiutil create -volname "OPEN_UP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "> packaged $DMG ($(du -h "$DMG" | cut -f1))"
