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
