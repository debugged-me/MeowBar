#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Signing is ad-hoc unless you opt in:
#   MEOWBAR_SIGN_ID="Developer ID Application: Your Name (TEAMID)"  → sign for distribution
#   MEOWBAR_NOTARY_PROFILE="meowbar"  → also notarize + staple the DMG
#     (create the profile once: xcrun notarytool store-credentials meowbar)
SIGN_ID="${MEOWBAR_SIGN_ID:--}"
NOTARY_PROFILE="${MEOWBAR_NOTARY_PROFILE:-}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' MeowBar/Info.plist)

APP="build/MeowBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp MeowBar/Info.plist "$APP/Contents/Info.plist"
cp MeowBar/Resources/* "$APP/Contents/Resources/"

swiftc -O -target arm64-apple-macos14.0 \
    -o "$APP/Contents/MacOS/MeowBar" \
    MeowBar/Sources/*.swift MeowBar/Sources/Core/*.swift

# statusline helper — installed as Claude Code's statusLine command when the
# "Always fresh" setting is enabled (pushes rate_limits to us, zero polling)
swiftc -O -target arm64-apple-macos14.0 \
    -o "$APP/Contents/MacOS/meowbar-statusline" \
    MeowBar/Sources/statusline/main.swift

if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - "$APP"
else
    # Hardened runtime + secure timestamp are required for notarization;
    # nested code is signed before the bundle that contains it.
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/meowbar-statusline"
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
echo "Built $APP ($VERSION, signed: $SIGN_ID)"

# Distributable DMG: app + /Applications symlink for drag-install.
# Finder records the installer window's layout in the staging folder's
# .DS_Store before imaging — no mounting required, and it's carried into
# the image wholesale. All best-effort: cosmetics never fail the build.
STAGING=$(mktemp -d)/MeowBar
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

osascript 2>/dev/null <<FEOF || true
tell application "Finder"
    set f to POSIX file "$STAGING" as alias
    set w to make new Finder window to f
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set bounds of w to {200, 120, 680, 360}
    set vo to icon view options of w
    set arrangement of vo to not arranged
    set icon size of vo to 88
    set position of item "MeowBar.app" of f to {130, 115}
    set position of item "Applications" of f to {335, 115}
    update f
    delay 0.5
    close w
end tell
FEOF

rm -f build/MeowBar.dmg
hdiutil create -volname "MeowBar" -srcfolder "$STAGING" -ov -format UDZO build/MeowBar.dmg >/dev/null
rm -rf "$(dirname "$STAGING")"

if [ "$SIGN_ID" != "-" ]; then
    codesign --force --timestamp --sign "$SIGN_ID" build/MeowBar.dmg
    if [ -n "$NOTARY_PROFILE" ]; then
        xcrun notarytool submit build/MeowBar.dmg --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple build/MeowBar.dmg
    fi
fi

# Update feed read by the in-app check (MeowBarUpdateURL in Info.plist points
# at wherever this file is hosted; "url" resolves relative to it).
printf '{ "version": "%s", "url": "MeowBar.dmg" }\n' "$VERSION" > build/version.json

cp build/MeowBar.dmg ./MeowBar.dmg   # sits next to index.html — same layout as production
cp build/version.json ./version.json
echo "Built build/MeowBar.dmg + version.json"
