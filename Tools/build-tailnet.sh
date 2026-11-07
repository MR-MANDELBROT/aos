#!/bin/bash
# Xcode build step of the aggregate target aos-tailnet (project.yml): builds aOS's Tailscale node for the Mac
# (Tailnet/build.sh mac, Go) into $BUILT_PRODUCTS_DIR/aos-tailnet and signs it like the app's other tools: the same
# identity, the hardened runtime, the identifier aos-tailnet (aos-powerd checks exactly that before it runs it). The
# aOS target then copies it into Contents/MacOS. Never automatic signing.
set -euo pipefail
OUT="${BUILT_PRODUCTS_DIR:?}/aos-tailnet"
"${SRCROOT:?}/Tailnet/build.sh" mac "$OUT"

[ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] && exit 0
IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  SIGN="-"
else
  # The identity's hash, so a second certificate with a similar name can't make codesign ambiguous.
  SIGN="$(security find-identity -v -p codesigning \
    | awk -v name="$IDENTITY" -v team="(${DEVELOPMENT_TEAM:-})" 'index($0, name) && index($0, team) { print $2; exit }')"
  [ -n "$SIGN" ] || { echo "error: no signing identity \"$IDENTITY\" of team ${DEVELOPMENT_TEAM:-?} for aos-tailnet" >&2; exit 1; }
fi
# Archives get a secure timestamp (notarization needs it), everyday builds don't (like Xcode's own signing).
TIMESTAMP="--timestamp=none"
if [ "${ACTION:-build}" = "install" ] && [ "$SIGN" != "-" ]; then TIMESTAMP="--timestamp"; fi
codesign --force --sign "$SIGN" --options runtime "$TIMESTAMP" --identifier aos-tailnet "$OUT"
