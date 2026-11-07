#!/bin/bash
# Generates iOS/aOS.xcodeproj from iOS/project.yml (XcodeGen via mint) and puts the pinned package versions in place.
set -euo pipefail
cd "$(dirname "$0")"
export MINT_PATH="${MINT_PATH:-$HOME/Developer/bitwarden-agent/mint}"

# The screen client's Go library (not checked in): built once from Open Screen Sharing's source.
Tools/libsharing.sh

# The app icon is the Mac app's Icon Composer document with iOS as its platform; refreshed here so both stay the same.
rm -rf Resources/AppIcon.icon
cp -R ../App/Resources/AppIcon.icon Resources/AppIcon.icon
sed -i '' 's/"macOS"/"iOS"/' Resources/AppIcon.icon/icon.json

# aOS's Tailscale node (Go, gomobile): built when it is missing or older than its sources (about a minute; the tests
# and the programs under cmd/ don't count).
FRAMEWORK=Frameworks/Tailnetkit.xcframework
if [ ! -d "$FRAMEWORK" ] || [ ../Tailnet/go.sum -nt "$FRAMEWORK" ] || [ -n "$(find ../Tailnet -name '*.go' \
     -not -name '*_test.go' -not -path '*/cmd/*' -not -path '*/internal/testnet/*' -newer "$FRAMEWORK" -print -quit)" ]; then
  ../Tailnet/build.sh ios "$FRAMEWORK"
fi

mint run yonaskolb/xcodegen generate --spec project.yml
# XcodeGen marks Icon Composer documents as wrapper.icon; Xcode needs folder.iconcomposer.icon to compile them.
sed -i '' 's/lastKnownFileType = wrapper.icon;/lastKnownFileType = folder.iconcomposer.icon;/' aOS.xcodeproj/project.pbxproj

# Exact package revisions (checked in as iOS/Package.resolved, because the generated project is not).
if [ -f Package.resolved ]; then
  mkdir -p aOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
  cp Package.resolved aOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
fi
