#!/bin/bash
# Packages build/SoundBar.app and the dist/ files into SoundBar.dmg.
#
#   ./scripts/build.sh && ./scripts/make-dmg.sh        -> ./build/SoundBar.dmg
#
# The image carries the app, an /Applications symlink for drag-installs, the
# installer/uninstaller (which handle the login agent — a plain drag cannot), and a
# read-me. The volume icon is the app icon.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$PROJECT_DIR/build/SoundBar.app"
STAGE="$PROJECT_DIR/build/dmg-stage"
OUT="$PROJECT_DIR/build/SoundBar.dmg"

[[ -d "$APP" ]] || { echo "error: $APP not found — run ./scripts/build.sh first" >&2; exit 1; }

echo "==> Staging"
rm -rf "$STAGE" "$OUT" "$PROJECT_DIR/build/rw.dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/SoundBar.app"
codesign --verify --strict "$STAGE/SoundBar.app"
ln -s /Applications "$STAGE/Applications"
cp "$PROJECT_DIR/dist/Install SoundBar.command" "$STAGE/"
cp "$PROJECT_DIR/dist/Uninstall SoundBar.command" "$STAGE/"
cp "$PROJECT_DIR/dist/Read Me.txt" "$STAGE/"
chmod +x "$STAGE"/*.command
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
find "$STAGE" -name '.DS_Store' -delete

echo "==> Building image"
hdiutil create -srcfolder "$STAGE" -volname "SoundBar" -fs HFS+ -format UDRW -ov \
  "$PROJECT_DIR/build/rw.dmg" >/dev/null
MP=$(hdiutil attach "$PROJECT_DIR/build/rw.dmg" -nobrowse -noautoopen | grep -o '/Volumes/.*$' | head -1)
# kHasCustomIcon lives in byte 8 of the volume's FinderInfo; without it .VolumeIcon.icns is ignored.
xattr -wx com.apple.FinderInfo \
  "0000000000000000040000000000000000000000000000000000000000000000" "$MP"
sync
hdiutil detach "$MP" >/dev/null
hdiutil convert "$PROJECT_DIR/build/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$PROJECT_DIR/build/rw.dmg"
rm -rf "$STAGE"

hdiutil verify "$OUT" >/dev/null && echo "==> Built $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
