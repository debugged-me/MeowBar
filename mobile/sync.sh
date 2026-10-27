#!/bin/sh
# Copies MeowBar's usage cache into htdocs so Apache (daemon user) can serve it.
# Runs as the user via com.meowbar.mobilesync LaunchAgent every 30s.
SRC="/Users/CLARk/Library/Application Support/MeowBar/usage-cache.json"
DST="/Applications/XAMPP/xamppfiles/htdocs/MeowBar/mobile/usage.json"
if [ -f "$SRC" ]; then
  cp "$SRC" "$DST.tmp" && mv "$DST.tmp" "$DST" && chmod 644 "$DST"
fi
