#!/bin/bash
# Builds Libsharing.xcframework (Open Screen Sharing's Go library, iPhone and simulator) for the screen client
# (target ScreenClient) into iOS/ThirdParty/OpenScreenSharing/. Not checked in: about 60 MB.
#
#   iOS/Tools/libsharing.sh           build it if it's missing
#   iOS/Tools/libsharing.sh --force   build it again
#   iOS/Tools/libsharing.sh --copy    take the one Open Screen Sharing's checkout built (`make lib`) instead
#
# OSS_SOURCE is the Open Screen Sharing checkout (default ~/Developer/open-screen-sharing); it is only read, the
# output goes here. Needs Go and gomobile at the version Open Screen Sharing pins (github.com/sagernet/gomobile, see
# its go.mod); this script installs nothing. Like Open Screen Sharing's own build (cmd/internal/build_libsharing):
# gomobile bind -target ios,iossimulator -iosversion 15.0 -trimpath -buildvcs=false -ldflags "-s -w ...".
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/ThirdParty/OpenScreenSharing/Libsharing.xcframework"
SRC="${OSS_SOURCE:-$HOME/Developer/open-screen-sharing}"
MODE="${1:-}"

if [ -d "$OUT" ] && [ "$MODE" != "--force" ] && [ "$MODE" != "--copy" ]; then
  exit 0
fi
if [ ! -f "$SRC/go.mod" ] || [ ! -d "$SRC/libsharing" ]; then
  echo "No Open Screen Sharing checkout at $SRC (set OSS_SOURCE)." >&2
  echo "Source: https://github.com/nekohasekai/open-screen-sharing" >&2
  exit 1
fi

# Which source this is (for the license's "corresponding source"): the checkout's branch and commit.
HEAD_REF=$(sed -n 's/^ref: //p' "$SRC/.git/HEAD" 2>/dev/null || true)
COMMIT=$(cat "$SRC/.git/$HEAD_REF" 2>/dev/null || cat "$SRC/.git/HEAD" 2>/dev/null || echo unknown)
echo "Open Screen Sharing at $SRC (${HEAD_REF#refs/heads/} ${COMMIT:0:12})"

if [ "$MODE" = "--copy" ]; then
  [ -d "$SRC/Frameworks/Libsharing.xcframework" ] || { echo "No built framework in $SRC/Frameworks" >&2; exit 1; }
  rm -rf "$OUT"
  cp -R "$SRC/Frameworks/Libsharing.xcframework" "$OUT"
  echo "copied to $OUT"
  exit 0
fi

GOBIN_DIR="$(go env GOPATH)/bin"
if [ ! -x "$GOBIN_DIR/gomobile" ] || [ ! -x "$GOBIN_DIR/gobind" ]; then
  echo "gomobile and gobind are missing in $GOBIN_DIR. Open Screen Sharing's 'make lib' installs the pinned ones." >&2
  exit 1
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
(
  cd "$SRC"
  PATH="$GOBIN_DIR:$PATH" GOTOOLCHAIN=local "$GOBIN_DIR/gomobile" bind -target ios,iossimulator -iosversion 15.0 \
    -trimpath -buildvcs=false -ldflags "-s -w -buildid= -checklinkname=0" -o "$WORK/Libsharing.xcframework" ./libsharing
)
rm -rf "$OUT"
mv "$WORK/Libsharing.xcframework" "$OUT"
echo "built $OUT"
