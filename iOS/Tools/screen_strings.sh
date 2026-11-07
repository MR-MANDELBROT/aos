#!/bin/bash
# Adds the screen client's strings (iOS/ThirdParty/OpenScreenSharing, which looks them up in the main bundle) to the
# app's string catalog as manual entries with their German (Tools/screen_strings.py), then runs Tools/localize.sh.
# Run it after taking new code from Open Screen Sharing. Never with signing.
set -euo pipefail
cd "$(dirname "$0")/.."
./generate.sh >/dev/null
OUT="$(cd .. && pwd)/build/ios-loc-screen"
rm -rf "$OUT"
# The module's strings are exported only here (localize.sh leaves the module out: its import would make the module a
# catalog of its own), with derived data of its own so nothing of this export stays for the next one
xcodebuild -exportLocalizations -project aOS.xcodeproj -scheme aOS -localizationPath "$OUT" -exportLanguage de \
  -derivedDataPath "$OUT-derived" -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO \
  SWIFT_EMIT_LOC_STRINGS=YES LOCALIZATION_EXPORT_SUPPORTED=YES >/dev/null 2>&1
python3 -I Tools/screen_strings.py "$OUT/de.xcloc/Localized Contents/de.xliff" Resources/Localizable.xcstrings \
  Tools/translations_de.py Tools/translations_screen_de.py
Tools/localize.sh
