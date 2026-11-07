#!/bin/bash
# Builds aOS's Tailscale node (Go, tailscale.com/tsnet; Docs/DESIGN.md, "Reaching the Mac on the go").
#
#   Tailnet/build.sh mac <output file>        aos-tailnet for the Mac app, for the architectures in $ARCHS (default
#                                             arm64); unsigned (the Xcode step "aos-tailnet" signs it)
#   Tailnet/build.sh ios <output .xcframework>  Tailnetkit for the iPhone app: a C library (c-archive) in a static
#                                             framework, for the iPhone and the simulator (arm64, x86_64)
#   Tailnet/build.sh test [go test flags]     the tests (Tailscale's test coordination server, no account)
#   Tailnet/build.sh testnet                  a whole tailnet on 127.0.0.1 for the iPhone's end-to-end test
#                                             (iOS/Tools/test-tailnet.sh); prints its admin URL, runs until stdin ends
#
# The build tags leave out every Tailscale feature that would offer something on the tailnet or take remote
# configuration: the peer API server, Taildrop, Tailscale SSH, the web client, Taildrive, the peer relay server,
# routes and exit nodes, remote configuration, packet capture, port lists and log uploads. (Serve and ACME stay: tsnet
# can't be built without them; the node never gets a serve configuration.) Binaries built without the tags refuse to
# start (tailnet.BuiltForAOS).
set -euo pipefail
# Output paths are the caller's: relative ones count from where it was started.
absolute() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
[ -n "${2:-}" ] && OUT="$(absolute "$2")"
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
    : "${OUT:?output file}"
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
    : "${OUT:?output .xcframework}"
    IOS_MIN=27.0
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    # One slice: GOOS=ios with Apple's clang for the SDK (the simulator is told by its SDK and version flag, the way
    # gomobile does it).
    slice() { # <sdk> <GOARCH> <clang arch> <version flag> <extra tags>
      local sysroot flags
      sysroot="$(xcrun --sdk "$1" --show-sdk-path)"
      flags="-isysroot $sysroot $4 -arch $3"
      GOOS=ios GOARCH="$2" CGO_ENABLED=1 CC="$(xcrun --sdk "$1" --find clang)" CGO_CFLAGS="$flags" CGO_LDFLAGS="$flags" \
        go build -buildmode=c-archive -tags "$TAGS,$5" -trimpath -buildvcs=false -ldflags "-s -w -buildid=" \
        -o "$WORK/$1-$3.a" ./tailnetkit
    }
    slice iphoneos arm64 arm64 "-miphoneos-version-min=$IOS_MIN" ios
    slice iphonesimulator arm64 arm64 "-mios-simulator-version-min=$IOS_MIN" ios,iossimulator
    slice iphonesimulator amd64 x86_64 "-mios-simulator-version-min=$IOS_MIN" ios,iossimulator
    lipo -create "$WORK/iphonesimulator-arm64.a" "$WORK/iphonesimulator-x86_64.a" -output "$WORK/iphonesimulator.a"
    # A static framework around each archive: the header and a module map, so Swift says `import Tailnetkit`.
    framework() { # <folder> <archive>
      local fw="$WORK/$1/Tailnetkit.framework"
      mkdir -p "$fw/Headers" "$fw/Modules"
      cp "$2" "$fw/Tailnetkit"
      cp tailnetkit/include/tailnetkit.h "$fw/Headers/"
      printf 'framework module Tailnetkit {\n  umbrella header "tailnetkit.h"\n  export *\n}\n' > "$fw/Modules/module.modulemap"
      plutil -create xml1 "$fw/Info.plist"
      plutil -insert CFBundleExecutable -string Tailnetkit "$fw/Info.plist"
      plutil -insert CFBundleIdentifier -string dev.marquart.aos.tailnetkit "$fw/Info.plist"
      plutil -insert CFBundleName -string Tailnetkit "$fw/Info.plist"
      plutil -insert CFBundlePackageType -string FMWK "$fw/Info.plist"
      plutil -insert CFBundleShortVersionString -string 1.0 "$fw/Info.plist"
      plutil -insert CFBundleVersion -string 1 "$fw/Info.plist"
      plutil -insert MinimumOSVersion -string "$IOS_MIN" "$fw/Info.plist"
    }
    framework device "$WORK/iphoneos-arm64.a"
    framework simulator "$WORK/iphonesimulator.a"
    rm -rf "$OUT"
    mkdir -p "$(dirname "$OUT")"
    xcodebuild -create-xcframework -framework "$WORK/device/Tailnetkit.framework" \
      -framework "$WORK/simulator/Tailnetkit.framework" -output "$OUT" >/dev/null
    ;;
  test)
    shift
    go test -tags "$TAGS" -count=1 "$@" ./...
    ;;
  testnet)
    go build -tags "$TAGS" -o "${TMPDIR:-/tmp}/aos-tailnet-testnet" ./cmd/aos-tailnet-testnet
    exec "${TMPDIR:-/tmp}/aos-tailnet-testnet"
    ;;
  *)
    sed -n '2,11p' "$0" >&2
    exit 2
    ;;
esac
