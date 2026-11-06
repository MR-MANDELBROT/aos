#!/bin/bash
# Generates iOS/aOS.xcodeproj from iOS/project.yml (XcodeGen via mint) and puts the pinned package versions in place.
set -euo pipefail
cd "$(dirname "$0")"
export MINT_PATH="${MINT_PATH:-$HOME/Developer/bitwarden-agent/mint}"

# The app icon is the Mac app's Icon Composer document with iOS as its platform; refreshed here so both stay the same.
rm -rf Resources/AppIcon.icon
cp -R ../App/Resources/AppIcon.icon Resources/AppIcon.icon
sed -i '' 's/"macOS"/"iOS"/' Resources/AppIcon.icon/icon.json

mint run yonaskolb/xcodegen generate --spec project.yml
# XcodeGen marks Icon Composer documents as wrapper.icon; Xcode needs folder.iconcomposer.icon to compile them.
sed -i '' 's/lastKnownFileType = wrapper.icon;/lastKnownFileType = folder.iconcomposer.icon;/' aOS.xcodeproj/project.pbxproj

# Exact package revisions (checked in as iOS/Package.resolved, because the generated project is not).
if [ -f Package.resolved ]; then
  mkdir -p aOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
  cp Package.resolved aOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
fi
