#!/bin/bash
# Builds the app. Usage: Tools/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
Tools/generate.sh >/dev/null
xcodebuild -project aOS.xcodeproj -scheme aOS -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation build 2>&1 | tee build/xcb.log | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
grep -q "BUILD SUCCEEDED" build/xcb.log
# A registered build product confuses the Local Network permission of the installed aOS (Docs/DESIGN.md).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "build/DerivedData/Build/Products/$CONFIG/aOS.app" 2>/dev/null || true
