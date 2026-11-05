#!/bin/bash
# Builds a release: archive (Release), export with Developer ID, notarize, staple, DMG (signed, notarized,
# stapled), Sparkle signature and appcast entry. Output in build/release/<version>/.
#
# One-time setup by the developer (never in this script, never in the repository):
#   1. Notarization credentials in the keychain:
#        xcrun notarytool store-credentials annex-notary --apple-id <Apple ID> --team-id S3725YB7V6
#      (asks for an app-specific password, created at account.apple.com)
#   2. Sparkle EdDSA key in the keychain, public key into project.yml (SUPublicEDKey):
#        build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
#
# Usage: Tools/release.sh            (version from project.yml: MARKETING_VERSION / CURRENT_PROJECT_VERSION)
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=S3725YB7V6
PROFILE="${NOTARY_PROFILE:-annex-notary}"
VERSION="$(awk -F': *' '/MARKETING_VERSION/ {print $2; exit}' project.yml | tr -d '"')"
BUILD="$(awk -F': *' '/CURRENT_PROJECT_VERSION/ {print $2; exit}' project.yml | tr -d '"')"
OUT="build/release/$VERSION"
ARCHIVE="$OUT/Annex.xcarchive"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }

grep -q "REPLACE_WITH_SPARKLE_PUBLIC_KEY" project.yml && die "set SUPublicEDKey in project.yml first (see the header)"
[ -z "$(git status --porcelain)" ] || die "the working tree has uncommitted changes"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || die "notarization profile $PROFILE missing (see the header)"

rm -rf "$OUT"; mkdir -p "$OUT"
say "generating the project"
Tools/generate.sh >/dev/null

say "archiving $VERSION ($BUILD)"
xcodebuild -project Annex.xcodeproj -scheme Annex -configuration Release -archivePath "$ARCHIVE" \
  -derivedDataPath build/DerivedData -skipPackagePluginValidation -skipMacroValidation archive \
  > "$OUT/archive.log" 2>&1 || { tail -30 "$OUT/archive.log"; die "archive failed"; }

cat > "$OUT/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
EOF
say "exporting"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" -exportOptionsPlist "$OUT/export.plist" \
  > "$OUT/export.log" 2>&1 || { tail -20 "$OUT/export.log"; die "export failed"; }
APP="$OUT/export/Annex.app"

say "checking the signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application: .*($TEAM)" || die "not signed with Developer ID ($TEAM)"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q com.apple.security.virtualization || die "virtualization entitlement missing"
for tool in annex-mcp annex-session; do
  codesign -dv "$APP/Contents/MacOS/$tool" 2>&1 | grep -q "flags=.*runtime" || die "$tool lacks the hardened runtime"
done

say "notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/Annex-notarize.zip"
xcrun notarytool submit "$OUT/Annex-notarize.zip" --keychain-profile "$PROFILE" --wait | tee "$OUT/notary-app.log"
grep -q "status: Accepted" "$OUT/notary-app.log" || die "notarization of the app failed"
xcrun stapler staple "$APP"
rm -f "$OUT/Annex-notarize.zip"

say "building the DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Annex.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Annex-$VERSION.dmg"
hdiutil create -volname "Annex $VERSION" -srcfolder "$STAGE" -ov -format ULFO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "Developer ID Application: Maximilian Marquart ($TEAM)" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait | tee "$OUT/notary-dmg.log"
grep -q "status: Accepted" "$OUT/notary-dmg.log" || die "notarization of the DMG failed"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

say "Sparkle signature"
SIGN_UPDATE="$(find build/DerivedData/SourcePackages/artifacts -name sign_update -type f | head -1)"
[ -x "$SIGN_UPDATE" ] || die "sign_update not found (build once so Sparkle is downloaded)"
SIG="$("$SIGN_UPDATE" "$DMG")"
SIZE="$(stat -f %z "$DMG")"
cat > "$OUT/appcast-item.xml" <<EOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/MR-MANDELBROT/annex/releases/download/v$VERSION/Annex-$VERSION.dmg" length="$SIZE" type="application/octet-stream" $SIG/>
    </item>
EOF
shasum -a 256 "$DMG" | tee "$OUT/SHA256SUMS"
say "done: $DMG"
say "next: create the GitHub release v$VERSION with the DMG, add appcast-item.xml to site/appcast.xml"
