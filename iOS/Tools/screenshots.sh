#!/bin/bash
# Screenshots of the demo screens (debug build, sample data, no network) in the simulator, light and dark,
# into build/ios-screenshots/<language>/.   iOS/Tools/screenshots.sh [de|en] [name ...]
set -euo pipefail
cd "$(dirname "$0")/.."
LANGUAGE="${1:-de}"
shift || true
OUT="$(cd .. && pwd)/build/ios-screenshots/$LANGUAGE"
mkdir -p "$OUT"
UDID=$(./Tools/sim.sh -AOSDemo YES | tail -1)
LOCALE=$([ "$LANGUAGE" = de ] && echo de_DE || echo en_US)
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularMode active --cellularBars 4 >/dev/null 2>&1 || true

SHOTS=(
  "welcome|-AOSDemoUnpaired YES"
  "overview|-AOSDemoTab overview"
  "requests|-AOSDemoTab overview -AOSDemoSheet requests"
  "signin|-AOSDemoTab overview -AOSDemoSheet signin"
  "signin-nomatch|-AOSDemoTab overview -AOSDemoSheet signin-none"
  "signin-code|-AOSDemoTab overview -AOSDemoSheet signin-code"
  "approval|-AOSDemoTab overview -AOSDemoSheet approval"
  "pairing|-AOSDemoTab overview -AOSDemoSheet pairing"
  "settings|-AOSDemoTab overview -AOSDemoSheet settings"
  "lock|-AOSDemoTab overview -AOSDemoSheet lock"
  "terminal-list|-AOSDemoTab terminal"
  "terminal|-AOSDemoTab terminal -AOSDemoSheet shell"
  "screen|-AOSDemoTab screen"
  "screen-help|-AOSDemoTab overview -AOSDemoSheet help"
  "vault|-AOSDemoTab vault"
  "vault-empty|-AOSDemoTab vault -AOSDemoEmptyVault YES"
  "vault-detail|-AOSDemoTab vault -AOSDemoSheet detail"
  "vault-editor|-AOSDemoTab vault -AOSDemoSheet editor"
  "vault-import|-AOSDemoTab vault -AOSDemoSheet import"
)

for appearance in light dark; do
  xcrun simctl ui "$UDID" appearance "$appearance"
  for entry in "${SHOTS[@]}"; do
    name=${entry%%|*}
    args=${entry#*|}
    if [ $# -gt 0 ] && [[ ! " $* " == *" $name "* ]]; then continue; fi
    # shellcheck disable=SC2086
    xcrun simctl launch --terminate-running-process "$UDID" dev.marquart.aos.ios -AOSDemo YES $args \
      -AppleLanguages "($LANGUAGE)" -AppleLocale "$LOCALE" >/dev/null
    sleep 3
    xcrun simctl io "$UDID" screenshot "$OUT/$name-$appearance.png" >/dev/null 2>&1
    echo "$OUT/$name-$appearance.png"
  done
done
