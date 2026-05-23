#!/usr/bin/env bash
#
# Rasterize Sources/Perch/Resources/AppIcon.svg into the macOS
# AppIcon.appiconset (deduplicated layout — 7 PNGs each reused
# across multiple idiom slots in Contents.json).
#
# Run after any edit to AppIcon.svg. The output PNGs and
# Contents.json are committed to the repo so the release pipeline
# doesn't need rsvg-convert; only this script does.
#
# Requires: rsvg-convert (brew install librsvg)
#
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="Sources/Perch/Resources/AppIcon.svg"
ASSETS="Sources/Perch/Resources/Assets.xcassets"
DEST="$ASSETS/AppIcon.appiconset"

[[ -f "$SRC" ]] || { echo "ERROR: $SRC not found" >&2; exit 1; }
command -v rsvg-convert >/dev/null \
    || { echo "ERROR: rsvg-convert not on PATH. Install: brew install librsvg" >&2; exit 1; }

mkdir -p "$DEST"

# Perch uses deduplicated PNGs: one file per pixel size, mapped to
# multiple idiom/scale slots in Contents.json (e.g. icon_32.png is
# both 16@2x and 32@1x).
sizes=(16 32 64 128 256 512 1024)

echo "==> Rasterizing $SRC"
for px in "${sizes[@]}"; do
    name="icon_${px}.png"
    printf "  %s  (%d×%d)\n" "$name" "$px" "$px"
    rsvg-convert -w "$px" -h "$px" "$SRC" -o "$DEST/$name"
done

cat > "$DEST/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

# Asset catalog root needs its own Contents.json so Xcode recognises
# the bundle.
if [[ ! -f "$ASSETS/Contents.json" ]]; then
    cat > "$ASSETS/Contents.json" <<'JSON'
{ "info" : { "version" : 1, "author" : "xcode" } }
JSON
fi

echo "==> Wrote $DEST + Contents.json"
