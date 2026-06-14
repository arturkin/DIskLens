#!/bin/sh
# Regenerate the DiskLens AppIcon images from scripts/make-icon.swift.
# Renders the 1024 master, then downscales into App/Assets.xcassets/AppIcon.appiconset.
# Run after editing make-icon.swift; the .appiconset Contents.json is hand-maintained.
set -e

DIR=$(cd "$(dirname "$0")/.." && pwd)
ICONSET="$DIR/App/Assets.xcassets/AppIcon.appiconset"
MASTER=$(mktemp -t diskicon).png

swift "$DIR/scripts/make-icon.swift" "$MASTER"
for sz in 16 32 64 128 256 512; do
    sips -z "$sz" "$sz" "$MASTER" --out "$ICONSET/icon_${sz}.png" >/dev/null
done
cp "$MASTER" "$ICONSET/icon_1024.png"
rm -f "$MASTER"
echo "Regenerated AppIcon images in $ICONSET"
