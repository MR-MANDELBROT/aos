#!/bin/bash
# Installs a freshly built aOS.app into /Applications for testing (development only; releases go through
# Tools/release.sh). Quits the running app (it closes the workspace in order), moves the old copy to the Trash and
# removes every other copy from LaunchServices: macOS identifies apps for Local Network permission by their
# executable's UUID, and several registered copies with different UUIDs make it refuse the network to the new one.
#
# Usage: Tools/install-dev.sh [Release|Debug]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Release}"
NEW="build/DerivedData/Build/Products/$CONFIG/aOS.app"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -d "$NEW" ] || { echo "build first: Tools/build.sh $CONFIG" >&2; exit 1; }

osascript -e 'tell application id "dev.marquart.aos" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 120); do pgrep -f "aOS.app/Contents/MacOS/aOS$" >/dev/null || break; sleep 1; done

if [ -d /Applications/aOS.app ]; then
  # Not named .app in the Trash: LaunchServices registers apps there again, and every registered copy confuses the
  # Local Network permission (it follows the executable's UUID)
  OLD="$HOME/.Trash/aOS-$(date +%Y%m%d-%H%M%S).app-alt"
  "$LSR" -u /Applications/aOS.app 2>/dev/null || true
  mv /Applications/aOS.app "$OLD"
  "$LSR" -u "$OLD" 2>/dev/null || true
fi
ditto "$NEW" /Applications/aOS.app
codesign --verify --deep --strict /Applications/aOS.app

# Only /Applications/aOS.app stays registered.
"$LSR" -dump 2>/dev/null | awk '/^path:/{p=$0} /^identifier: *dev\.marquart\.aos(\.guest-helper)?$/{print p}' \
  | sed -E 's/^path: *//; s/ \(0x[0-9a-f]+\)$//' | sort -u | while read -r app; do
    case "$app" in
      /Applications/aOS.app|/Applications/aOS.app/*) ;;
      *) "$LSR" -u "$app" 2>/dev/null || true ;;
    esac
  done
"$LSR" -f /Applications/aOS.app

open -g -b dev.marquart.aos
echo "installed $(dwarfdump --uuid /Applications/aOS.app/Contents/MacOS/aOS | awk '{print $2}')"
