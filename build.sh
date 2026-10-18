#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MeowBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp MeowBar/Info.plist "$APP/Contents/Info.plist"

swiftc -O -target arm64-apple-macos14.0 \
    -o "$APP/Contents/MacOS/MeowBar" \
    MeowBar/Sources/*.swift

codesign --force --sign - "$APP"
echo "Built $APP"
