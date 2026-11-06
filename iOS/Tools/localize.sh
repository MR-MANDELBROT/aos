#!/bin/bash
# Exports the app's strings, fills German from iOS/Tools/translations_de.py and imports them into the string catalogs
# (iOS/Resources/Localizable.xcstrings, InfoPlist.xcstrings). Prints English strings that have no German yet.
#   iOS/Tools/localize.sh            export, fill, import
#   iOS/Tools/localize.sh --check    only list what's missing
set -euo pipefail
cd "$(dirname "$0")/.."
./generate.sh >/dev/null
OUT="$(cd .. && pwd)/build/ios-loc"
rm -rf "$OUT"
xcodebuild -exportLocalizations -project aOS.xcodeproj -localizationPath "$OUT" -exportLanguage de \
  -skipPackagePluginValidation -skipMacroValidation >/dev/null 2>&1
X="$OUT/de.xcloc/Localized Contents/de.xliff"
python3 -I Tools/fill_xliff.py "$X" Tools/translations_de.py ${1:-}
if [ "${1:-}" != "--check" ]; then
  xcodebuild -importLocalizations -project aOS.xcodeproj -localizationPath "$OUT/de.xcloc" \
    -skipPackagePluginValidation -skipMacroValidation >/dev/null 2>&1
  echo "imported"
fi
