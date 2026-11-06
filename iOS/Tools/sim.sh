#!/bin/bash
# Builds the app, installs it in the iOS Simulator and starts it. Arguments go to the app, for example the demo:
#
#   iOS/Tools/sim.sh -AOSDemo YES -AOSDemoTab vault
#   iOS/Tools/sim.sh --no-build -AOSDemo YES -AOSDemoSheet signin
#
# Like test.sh, it lowers the deployment target for this build when the simulator runs an older iOS.
# AOS_SIM_DEVICE picks another simulator; the UDID is printed for `xcrun simctl io <udid> screenshot`.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE_NAME="${AOS_SIM_DEVICE:-iPhone 17 Pro}"
DERIVED="${AOS_DERIVED_DATA:-$(cd .. && pwd)/build/ios-sim}"
BUILD=1
if [ "${1:-}" = "--no-build" ]; then BUILD=0; shift; fi

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

if [ "$BUILD" = 1 ]; then
  ./generate.sh >/dev/null
  TARGET_ARGS=()
  if python3 -I -c 'import sys; sys.exit(0 if [int(x) for x in sys.argv[1].split(".")] < [27, 0] else 1)' "$RUNTIME"; then
    TARGET_ARGS=(IPHONEOS_DEPLOYMENT_TARGET="$RUNTIME")
  fi
  xcodebuild -project aOS.xcodeproj -scheme aOS -derivedDataPath "$DERIVED" \
    -destination 'generic/platform=iOS Simulator' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    -skipPackagePluginValidation -skipMacroValidation ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"} build -quiet
fi

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" "$DERIVED/Build/Products/Debug-iphonesimulator/aOS.app"
xcrun simctl launch --terminate-running-process "$UDID" dev.marquart.aos.ios "$@" >/dev/null
echo "$UDID"
