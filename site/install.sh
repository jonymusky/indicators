#!/bin/sh
# Indicators installer — https://indicators.jonymusky.com
# Downloads the latest release of Indicators.app into /Applications and launches it.
set -eu

REPO="jonymusky/indicators"
APP="/Applications/Indicators.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ "$(uname -s)" = "Darwin" ] || { echo "Indicators is a macOS app."; exit 1; }

echo "▸ Looking up the latest release…"
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*Indicators\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
[ -n "$URL" ] || { echo "No release found yet. Build from source: https://github.com/$REPO#build-from-source"; exit 1; }

echo "▸ Downloading $URL"
curl -fL --progress-bar "$URL" -o "$TMP/Indicators.zip"
ditto -x -k "$TMP/Indicators.zip" "$TMP"
[ -d "$TMP/Indicators.app" ] || { echo "Unexpected archive layout."; exit 1; }

if pgrep -x Indicators >/dev/null 2>&1; then
  echo "▸ Quitting the running copy…"
  osascript -e 'tell application "Indicators" to quit' >/dev/null 2>&1 || pkill -x Indicators || true
  sleep 1
fi

echo "▸ Installing to $APP"
rm -rf "$APP"
ditto "$TMP/Indicators.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "▸ Launching"
open "$APP"
echo "✓ Indicators is in your menu bar. Settings: click the gauge icon → ⚙"
