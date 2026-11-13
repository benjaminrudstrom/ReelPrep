#!/bin/sh
# Draws the app icon and builds assets/AppIcon.icns (all macOS sizes).
set -e
cd "$(dirname "$0")/.."
# The user's logo (a picture of the icon) when there is one; else the drawn "frames on the beat".
if [ -f assets/icon-source.jpg ]; then
  swift scripts/icon_from_image.swift assets/icon-source.jpg assets/AppIcon.png
else
  swift scripts/make_icon.swift assets/AppIcon.png
fi
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/AppIcon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d assets/AppIcon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
echo "Built assets/AppIcon.icns"
