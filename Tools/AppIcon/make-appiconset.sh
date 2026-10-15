#!/bin/sh
# Regenerates the PNGs in Resources/Assets.xcassets/AppIcon.appiconset from the generator.
#
#     Tools/AppIcon/make-appiconset.sh
#
# Draws the 1024-point master with generate-app-icon.swift, then derives every other size
# from that one master with sips. Contents.json is committed and not touched here: it only
# names the files below.
#
# macOS wants 16, 32, 128, 256 and 512 points at 1x and 2x, which is these pixel sizes:
#
#     16  32  64  128  256  512  1024
#
# The 1024 master is used as-is for icon_512x512@2x.png rather than resampled.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
iconset="$(cd "$here/../.." && pwd)/Resources/Assets.xcassets/AppIcon.appiconset"

if [ ! -d "$iconset" ]; then
    echo "error: $iconset does not exist; Contents.json is committed with the catalog" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swift "$here/generate-app-icon.swift" "$work" >/dev/null
master="$work/AppIcon-1024.png"

for entry in \
    16:icon_16x16 \
    32:icon_16x16@2x \
    32:icon_32x32 \
    64:icon_32x32@2x \
    128:icon_128x128 \
    256:icon_128x128@2x \
    256:icon_256x256 \
    512:icon_256x256@2x \
    512:icon_512x512; do
    pixels=${entry%%:*}
    name=${entry#*:}
    sips --resampleHeightWidth "$pixels" "$pixels" "$master" \
        --out "$iconset/$name.png" >/dev/null
done

cp "$master" "$iconset/icon_512x512@2x.png"
echo "wrote 10 icons to $iconset"
