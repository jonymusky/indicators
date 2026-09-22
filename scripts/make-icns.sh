#!/usr/bin/env bash
# Converts a 1024x1024 PNG into an .icns using only sips + iconutil.
set -euo pipefail
SRC="$1"; DST="$2"
TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$TMP"
for size in 16 32 128 256 512; do
  sips -z $size $size "$SRC" --out "$TMP/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$SRC" --out "$TMP/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$TMP" -o "$DST"
