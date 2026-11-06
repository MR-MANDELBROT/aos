#!/bin/bash
# Renders the app icon (iOS/Resources/AppIcon.icon) as pictures for use inside the app (lock screen, welcome page):
# Resources/Assets.xcassets/AppIconArt.imageset, light and dark. Run after the icon changes (generate.sh copies it).
set -euo pipefail
cd "$(dirname "$0")/.."
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
OUT=Resources/Assets.xcassets/AppIconArt.imageset
mkdir -p "$OUT"
"$ICTOOL" Resources/AppIcon.icon --export-image --output-file "$OUT/icon-light.png" \
  --platform iOS --rendition Default --width 128 --height 128 --scale 3
"$ICTOOL" Resources/AppIcon.icon --export-image --output-file "$OUT/icon-dark.png" \
  --platform iOS --rendition Dark --width 128 --height 128 --scale 3
cat > "$OUT/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon-light.png", "idiom" : "universal" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "icon-dark.png", "idiom" : "universal" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "preserves-vector-representation" : false }
}
JSON
echo "rendered into $OUT"
