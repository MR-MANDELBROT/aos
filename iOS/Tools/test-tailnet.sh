#!/bin/bash
# The iPhone app's end-to-end test of aOS's own Tailscale, without an account or the internet: a whole tailnet on
# this Mac (Tailnet/build.sh testnet: Tailscale's test coordination server, DERP, a "Mac" node with aOS's node code),
# and in the simulator the app's real Tailnetkit node signs in, dials the Mac node's port 22 and reaches the test's
# SSH server (iOS/Tests/TailnetEndToEndTests.swift). Nothing of the real Mac's Tailscale or sshd is touched.
#
#   iOS/Tools/test-tailnet.sh <simulator udid>
#
# Builds without automatic signing (never with it: it can remove the Xcode account).
set -euo pipefail
cd "$(dirname "$0")/.."
SIM="${1:?usage: iOS/Tools/test-tailnet.sh <simulator udid>}"
DERIVED="${AOS_DERIVED_DATA:-$(cd .. && pwd)/build/ios-tailnet}"
./generate.sh >/dev/null

xcodebuild -project aOS.xcodeproj -scheme aOS -derivedDataPath "$DERIVED" -destination "id=$SIM" \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= build-for-testing -quiet

# The tailnet runs as long as its stdin stays open: a FIFO this script holds open on descriptor 3.
WORK="$(mktemp -d)"
mkfifo "$WORK/stdin"
../Tailnet/build.sh testnet < "$WORK/stdin" > "$WORK/out" &
TESTNET=$!
exec 3>"$WORK/stdin"
trap 'exec 3>&-; wait "$TESTNET" 2>/dev/null || true; rm -rf "$WORK"' EXIT
ADMIN=""
for _ in $(seq 1 600); do
  ADMIN="$(head -1 "$WORK/out" 2>/dev/null || true)"
  [ -n "$ADMIN" ] && break
  kill -0 "$TESTNET" 2>/dev/null || { echo "the tailnet didn't start" >&2; exit 1; }
  sleep 0.2
done
[ -n "$ADMIN" ] || { echo "the tailnet didn't start in time" >&2; exit 1; }
echo "tailnet on this Mac: $ADMIN"

XCTESTRUN=$(ls -t "$DERIVED"/Build/Products/*.xctestrun | head -1)
TEST_RUNNER_AOS_TAILNET_TESTNET="$ADMIN" xcodebuild test-without-building -xctestrun "$XCTESTRUN" \
  -destination "id=$SIM" -only-testing:AOSTests/TailnetEndToEndTests
