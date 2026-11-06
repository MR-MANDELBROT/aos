#!/bin/bash
# Builds the app and its unit tests and runs them in the iOS Simulator.
#
#   iOS/Tools/test.sh                      all tests on "iPhone 17 Pro"
#   iOS/Tools/test.sh AOSTests/TOTPTests  only some (xcodebuild -only-testing)
#
# The app targets iOS 27. When the chosen simulator runs an older iOS (only an iOS 26 runtime installed), the
# deployment target is lowered for this build only, so the tests still run. AOS_SIM_DEVICE picks another simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
./generate.sh >/dev/null
DEVICE_NAME="${AOS_SIM_DEVICE:-iPhone 17 Pro}"
DERIVED="${AOS_DERIVED_DATA:-$(cd .. && pwd)/build/ios-sim}"

read -r UDID RUNTIME < <(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
name = sys.argv[1]
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS" not in runtime: continue
    version = runtime.rsplit("iOS-", 1)[-1].replace("-", ".")
    for d in devices:
        if d["name"] == name and (best is None or [int(x) for x in version.split(".")] > [int(x) for x in best[1].split(".")]):
            best = (d["udid"], version)
if best is None: sys.exit("no simulator named " + name)
print(*best)
' "$DEVICE_NAME")

TARGET_ARGS=()
if python3 -I -c 'import sys; sys.exit(0 if [int(x) for x in sys.argv[1].split(".")] < [27, 0] else 1)' "$RUNTIME"; then
  TARGET_ARGS=(IPHONEOS_DEPLOYMENT_TARGET="$RUNTIME")
  echo "Simulator runs iOS $RUNTIME: building with IPHONEOS_DEPLOYMENT_TARGET=$RUNTIME for this test run."
fi

ONLY=()
for t in "$@"; do ONLY+=(-only-testing:"$t"); done

xcodebuild -project aOS.xcodeproj -scheme aOS -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=iOS Simulator' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  -skipPackagePluginValidation -skipMacroValidation ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"} build-for-testing -quiet

XCTESTRUN=$(ls -t "$DERIVED"/Build/Products/*.xctestrun | head -1)
xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$UDID" ${ONLY[@]+"${ONLY[@]}"}
