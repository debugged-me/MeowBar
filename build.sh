#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MeowBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp MeowBar/Info.plist "$APP/Contents/Info.plist"
cp MeowBar/Resources/* "$APP/Contents/Resources/"

swiftc -O -target arm64-apple-macos14.0 \
    -o "$APP/Contents/MacOS/MeowBar" \
    MeowBar/Sources/*.swift

# statusline helper — installed as Claude Code's statusLine command when the
# "Always fresh" setting is enabled (pushes rate_limits to us, zero polling)
swiftc -O -target arm64-apple-macos14.0 \
    -o "$APP/Contents/MacOS/meowbar-statusline" \
    MeowBar/Sources/statusline/main.swift

codesign --force --sign - "$APP"
echo "Built $APP"

# Distributable DMG: app + /Applications symlink for drag-install
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f build/MeowBar.dmg
hdiutil create -volname "MeowBar" -srcfolder "$STAGING" -ov -format UDZO build/MeowBar.dmg >/dev/null
rm -rf "$STAGING"
cp build/MeowBar.dmg ./MeowBar.dmg   # sits next to index.html — same layout as production
echo "Built build/MeowBar.dmg"
