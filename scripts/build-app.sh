#!/usr/bin/env bash
# Builds Indicators.app from the SwiftPM package. Only Xcode Command Line Tools are required.
#
#   scripts/build-app.sh            -> build/Indicators.app (release)
#   VERSION=1.2.0 scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
CONFIG="${CONFIG:-release}"
OUT="build/Indicators.app"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG" 2>&1 | grep -vE "ld: warning: search path" || true
BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BINDIR/Indicators"
[ -x "$BIN" ] || { echo "build failed: $BIN not found"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Indicators"
# Companions ship inside the bundle: indicators-cli (terminal report) and indicators-mcp (MCP server).
cp "$BINDIR/indicators-cli" "$BINDIR/indicators-mcp" "$OUT/Contents/MacOS/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$OUT/Contents/Info.plist"
echo -n "APPL????" > "$OUT/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
elif [ -f Resources/AppIcon.png ] && command -v iconutil >/dev/null; then
  scripts/make-icns.sh Resources/AppIcon.png "$OUT/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature so macOS keeps a stable identity for Keychain and login-item permissions.
codesign --force --sign - --identifier com.jonymusky.indicators "$OUT" >/dev/null 2>&1 || true
echo "✓ $OUT (v$VERSION build $BUILD_NUMBER)"
