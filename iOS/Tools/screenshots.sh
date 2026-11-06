#!/bin/bash
# Screenshots of the demo screens (debug build, sample data, no network) in the simulator, light and dark,
# into build/ios-screenshots/<language>/.   iOS/Tools/screenshots.sh [de|en] [name ...]
set -euo pipefail
cd "$(dirname "$0")/.."
LANGUAGE="${1:-de}"
shift || true
OUT="$(cd .. && pwd)/build/ios-screenshots/$LANGUAGE"
mkdir -p "$OUT"
UDID=$(./Tools/sim.sh -AnnexDemo YES | tail -1)
LOCALE=$([ "$LANGUAGE" = de ] && echo de_DE || echo en_US)
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularMode active --cellularBars 4 >/dev/null 2>&1 || true

SHOTS=(
  "welcome|-AnnexDemoUnpaired YES"
  "overview|-AnnexDemoTab overview"
  "requests|-AnnexDemoTab overview -AnnexDemoSheet requests"
  "signin|-AnnexDemoTab overview -AnnexDemoSheet signin"
  "signin-nomatch|-AnnexDemoTab overview -AnnexDemoSheet signin-none"
  "pairing|-AnnexDemoTab overview -AnnexDemoSheet pairing"
  "settings|-AnnexDemoTab overview -AnnexDemoSheet settings"
  "lock|-AnnexDemoTab overview -AnnexDemoSheet lock"
  "terminal-list|-AnnexDemoTab terminal"
  "terminal|-AnnexDemoTab terminal -AnnexDemoSheet shell"
  "screen|-AnnexDemoTab screen"
  "screen-help|-AnnexDemoTab overview -AnnexDemoSheet help"
  "vault|-AnnexDemoTab vault"
  "vault-empty|-AnnexDemoTab vault -AnnexDemoEmptyVault YES"
  "vault-detail|-AnnexDemoTab vault -AnnexDemoSheet detail"
  "vault-editor|-AnnexDemoTab vault -AnnexDemoSheet editor"
  "vault-import|-AnnexDemoTab vault -AnnexDemoSheet import"
)

for appearance in light dark; do
  xcrun simctl ui "$UDID" appearance "$appearance"
  for entry in "${SHOTS[@]}"; do
    name=${entry%%|*}
    args=${entry#*|}
    if [ $# -gt 0 ] && [[ ! " $* " == *" $name "* ]]; then continue; fi
    # shellcheck disable=SC2086
    xcrun simctl launch --terminate-running-process "$UDID" dev.marquart.annex.ios -AnnexDemo YES $args \
      -AppleLanguages "($LANGUAGE)" -AppleLocale "$LOCALE" >/dev/null
    sleep 3
    xcrun simctl io "$UDID" screenshot "$OUT/$name-$appearance.png" >/dev/null 2>&1
    echo "$OUT/$name-$appearance.png"
  done
done
