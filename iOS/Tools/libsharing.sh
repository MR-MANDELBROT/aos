#!/bin/bash
# Builds Libsharing.xcframework (Open Screen Sharing's Go library, iPhone and simulator, with aOS's changes) for the
# screen client (target ScreenClient) into iOS/ThirdParty/OpenScreenSharing/. Not checked in: about 60 MB.
#
#   iOS/Tools/libsharing.sh           build it if it's missing or older than its source and aOS's patch
#   iOS/Tools/libsharing.sh --force   build it again
#
# OSS_SOURCE is the Open Screen Sharing checkout (default ~/Developer/open-screen-sharing); it is only read: its Go
# module (go.mod, go.sum, libsharing/, internal/) is copied, aOS's changes (ThirdParty/OpenScreenSharing/
# libsharing-aos.patch) are applied to the copy, their tests run, and the copy is built. Needs Go and gomobile at the
# version Open Screen Sharing pins (github.com/sagernet/gomobile, see its go.mod); this script installs nothing. Like
# Open Screen Sharing's own build (cmd/internal/build_libsharing): gomobile bind -target ios,iossimulator
# -iosversion 15.0 -trimpath -buildvcs=false -ldflags "-s -w ...".
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/ThirdParty/OpenScreenSharing/Libsharing.xcframework"
# What the framework was built from (checkout's commit and the patch's hash); a different one builds it again.
STAMP_FILE="$PWD/ThirdParty/OpenScreenSharing/Libsharing.source"
PATCH="$PWD/ThirdParty/OpenScreenSharing/libsharing-aos.patch"
SRC="${OSS_SOURCE:-$HOME/Developer/open-screen-sharing}"
MODE="${1:-}"

if [ ! -f "$SRC/go.mod" ] || [ ! -d "$SRC/libsharing" ]; then
  if [ -d "$OUT" ] && [ "$MODE" != "--force" ]; then
    echo "No Open Screen Sharing checkout at $SRC: keeping the Libsharing.xcframework there is." >&2
    exit 0
  fi
  echo "No Open Screen Sharing checkout at $SRC (set OSS_SOURCE)." >&2
  echo "Source: https://github.com/nekohasekai/open-screen-sharing" >&2
  exit 1
fi

# Which source this is (for the license's "corresponding source"): the checkout's branch and commit, and aOS's patch.
HEAD_REF=$(sed -n 's/^ref: //p' "$SRC/.git/HEAD" 2>/dev/null || true)
COMMIT=$(cat "$SRC/.git/$HEAD_REF" 2>/dev/null || cat "$SRC/.git/HEAD" 2>/dev/null || echo unknown)
STAMP="open-screen-sharing ${HEAD_REF#refs/heads/} $COMMIT, aOS patch $(shasum -a 256 "$PATCH" | cut -d' ' -f1)"
if [ -d "$OUT" ] && [ "$MODE" != "--force" ] && [ "$(cat "$STAMP_FILE" 2>/dev/null || true)" = "$STAMP" ]; then
  exit 0
fi
echo "Open Screen Sharing at $SRC (${HEAD_REF#refs/heads/} ${COMMIT:0:12}), with aOS's patch"

GOBIN_DIR="$(go env GOPATH)/bin"
if [ ! -x "$GOBIN_DIR/gomobile" ] || [ ! -x "$GOBIN_DIR/gobind" ]; then
  echo "gomobile and gobind are missing in $GOBIN_DIR. Open Screen Sharing's 'make lib' installs the pinned ones." >&2
  exit 1
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/src"
cp -R "$SRC/go.mod" "$SRC/go.sum" "$SRC/libsharing" "$SRC/internal" "$WORK/src/"
patch -p1 -s -d "$WORK/src" < "$PATCH"
(
  cd "$WORK/src"
  GOTOOLCHAIN=local go test -count=1 -run AOS ./internal/rfb/ >/dev/null
  PATH="$GOBIN_DIR:$PATH" GOTOOLCHAIN=local "$GOBIN_DIR/gomobile" bind -target ios,iossimulator -iosversion 15.0 \
    -trimpath -buildvcs=false -ldflags "-s -w -buildid= -checklinkname=0" -o "$WORK/Libsharing.xcframework" ./libsharing
)
rm -rf "$OUT"
mv "$WORK/Libsharing.xcframework" "$OUT"
echo "$STAMP" > "$STAMP_FILE"
echo "built $OUT"
