#!/bin/bash
# Builds aOS's Tailscale node (Go, tailscale.com/tsnet; Docs/DESIGN.md, "Reaching the Mac on the go").
#
#   Tailnet/build.sh mac <output file>        aos-tailnet for the Mac app, for the architectures in $ARCHS (default
#                                             arm64); unsigned (the Xcode step "aos-tailnet" signs it)
#   Tailnet/build.sh ios <output .xcframework>  Tailnetkit for the iPhone app (gomobile bind; device and simulator)
#   Tailnet/build.sh test [go test flags]     the tests (Tailscale's test coordination server, no account)
#
# The build tags leave out every Tailscale feature that would offer something on the tailnet or take remote
# configuration: the peer API server, Taildrop, Tailscale SSH, the web client, Taildrive, the peer relay server,
# routes and exit nodes, remote configuration, packet capture, port lists and log uploads. (Serve and ACME stay: tsnet
# can't be built without them; the node never gets a serve configuration.) Binaries built without the tags refuse to
# start (tailnet.BuiltForAOS).
set -euo pipefail
cd "$(dirname "$0")"
# Xcode's build steps run with a short PATH.
export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$HOME/go/bin:$PATH"
# go.mod asks for a newer Go than the installed one: Go fetches that toolchain once (golang.org/toolchain).
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"

TAGS="ts_omit_peerapiserver,ts_omit_taildrop,ts_omit_ssh,ts_omit_webclient,ts_omit_drive"
TAGS+=",ts_omit_relayserver,ts_omit_advertiseexitnode,ts_omit_advertiseroutes,ts_omit_bird,ts_omit_remoteconfig"
TAGS+=",ts_omit_appconnectors,ts_omit_capture,ts_omit_clientupdate,ts_omit_wakeonlan,ts_omit_portlist"
TAGS+=",ts_omit_netlog,ts_omit_logtail"

case "${1:-}" in
  mac)
    OUT="${2:?output file}"
    mkdir -p "$(dirname "$OUT")"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    SLICES=()
    for arch in ${ARCHS:-arm64}; do
      case "$arch" in
        arm64) goarch=arm64 ;;
        x86_64) goarch=amd64 ;;
        *) continue ;;
      esac
      CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" go build -tags "$TAGS" -trimpath -buildvcs=false \
        -ldflags "-s -w -buildid=" -o "$WORK/aos-tailnet-$arch" ./cmd/aos-tailnet
      SLICES+=("$WORK/aos-tailnet-$arch")
    done
    [ ${#SLICES[@]} -gt 0 ] || { echo "no architecture to build for (ARCHS=${ARCHS:-})" >&2; exit 1; }
    lipo -create "${SLICES[@]}" -output "$WORK/aos-tailnet"
    mv -f "$WORK/aos-tailnet" "$OUT"
    ;;
  ios)
    OUT="${2:?output .xcframework}"
    command -v gomobile >/dev/null || { echo "gomobile is missing: go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.13 github.com/sagernet/gomobile/cmd/gobind@v0.1.13" >&2; exit 1; }
    rm -rf "$OUT"
    mkdir -p "$(dirname "$OUT")"
    gomobile bind -target ios,iossimulator -iosversion 27.0 -tags "$TAGS" -trimpath -buildvcs=false \
      -ldflags "-s -w -buildid=" -o "$OUT" ./tailnetkit
    ;;
  test)
    shift
    go test -tags "$TAGS" -count=1 "$@" ./...
    ;;
  *)
    sed -n '2,12p' "$0" >&2
    exit 2
    ;;
esac
