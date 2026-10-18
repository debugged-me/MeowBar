#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MeowBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp MeowBar/Info.plist "$APP/Contents/Info.plist"
cp MeowBar/Resources/*.png "$APP/Contents/Resources/"

swiftc -O -target arm64-apple-macos14.0 \
    -o "$APP/Contents/MacOS/MeowBar" \
    MeowBar/Sources/*.swift

codesign --force --sign - "$APP"
echo "Built $APP"
