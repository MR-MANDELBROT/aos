#!/bin/bash
# Generates aOS.xcodeproj from project.yml (XcodeGen via mint).
set -euo pipefail
cd "$(dirname "$0")/.."
export MINT_PATH="${MINT_PATH:-$HOME/Developer/bitwarden-agent/mint}"
mint run yonaskolb/xcodegen generate --spec project.yml
# XcodeGen marks Icon Composer documents as wrapper.icon; Xcode needs folder.iconcomposer.icon to compile them.
sed -i '' 's/lastKnownFileType = wrapper.icon;/lastKnownFileType = folder.iconcomposer.icon;/' aOS.xcodeproj/project.pbxproj
