#!/bin/bash
# Builds the Go library of aOS's Android app, Android/third_party/aosgo/aosgo.aar (+ aosgo-sources.jar; not checked
# in, like the iPhone's xcframeworks; third_party/README.md describes it). One gomobile bind of two packages:
#
#   libsharing   Open Screen Sharing's Go library (GPL-3.0), copied from OSS_SOURCE (default
#                ~/Developer/open-screen-sharing, only read) with iOS/ThirdParty/OpenScreenSharing/libsharing-aos.patch
#                and third_party/libsharing-android.patch. Java package dev.marquart.aos.libsharing.
#   tailnetkit   aOS's Tailscale node (Tailnet/mobile), with Tailnet/build.sh's build tags. Java package
#                dev.marquart.aos.tailnetkit.
#
# One library, not two: on Android 10 and later every Go runtime keeps its goroutine pointer in the same thread-local
# slot (TLS_SLOT_APP, Go's runtime/cgo/gcc_android.c), so two Go libraries in one app crash as soon as one thread
# calls both (seen in the emulator). Two gomobile libraries also bring the same Java classes (go.Seq, ...).
#
# For android/arm64 (arm64-v8a) and android/amd64 (x86_64, the emulator), minimum API 29. The patch's Go tests and
# Tailnet's tests (Tailnet/build.sh test) run first.
#
#   Android/Tools/go-android.sh            build it if it's missing or out of date
#   Android/Tools/go-android.sh --force    build it again
#
# aosgo.source next to the aar records what it was built from (Open Screen Sharing's commit, both patches' hashes,
# Tailnet's files, the toolchain and this script); a difference builds it again.
#
# Needs Go, gomobile and gobind at the version Open Screen Sharing pins (github.com/sagernet/gomobile in its go.mod;
# its 'make lib' installs them), a JDK (JAVA_HOME, default Homebrew's openjdk@17), the Android SDK (ANDROID_HOME,
# default Homebrew's android-commandlinetools) with a platform and the NDK (ANDROID_NDK_HOME, default the newest in
# $ANDROID_HOME/ndk). It installs nothing; Go may fetch the modules Tailnet adds to Open Screen Sharing's.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
THIRD="$ROOT/Android/third_party"
OUT_DIR="$THIRD/aosgo"
OUT="$OUT_DIR/aosgo.aar"
STAMP_FILE="$OUT_DIR/aosgo.source"
AOS_PATCH="$ROOT/iOS/ThirdParty/OpenScreenSharing/libsharing-aos.patch"
ANDROID_PATCH="$THIRD/libsharing-android.patch"
TAILNET="$ROOT/Tailnet"
SRC="${OSS_SOURCE:-$HOME/Developer/open-screen-sharing}"
MIN_API=29

FORCE=0
case "${1:-}" in
  "") ;;
  --force) FORCE=1 ;;
  *) sed -n '2,21p' "$0" >&2; exit 2 ;;
esac

# MARK: Tools

export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$HOME/go/bin:$PATH"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME=$(ls -d "$ANDROID_HOME"/ndk/*/ 2>/dev/null | sort -V | tail -1 || true)
  ANDROID_NDK_HOME="${ANDROID_NDK_HOME%/}"
fi
export ANDROID_NDK_HOME
export PATH="$JAVA_HOME/bin:$PATH"
[ -x "$JAVA_HOME/bin/javac" ] || { echo "No JDK at $JAVA_HOME (set JAVA_HOME)." >&2; exit 1; }
[ -f "$ANDROID_NDK_HOME/source.properties" ] ||
  { echo "No Android NDK (set ANDROID_NDK_HOME or install ndk;<version> with sdkmanager)." >&2; exit 1; }
ANDROID_JAR=$(ls -d "$ANDROID_HOME"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1 || true)
[ -f "$ANDROID_JAR" ] || { echo "No Android platform in $ANDROID_HOME/platforms." >&2; exit 1; }
NDK_VERSION=$(sed -n 's/^Pkg.Revision *= *//p' "$ANDROID_NDK_HOME/source.properties")
NDK_BIN=$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin | head -1)
GOBIN_DIR="$(go env GOPATH)/bin"
ABIS="arm64-v8a x86_64"

# zip_add <archive> <dir>: adds the files below dir to archive (replacing ones of the same name), with fixed dates
# so the same input gives the same archive.
zip_add() {
  python3 -I - "$1" "$2" <<'PY'
import os, sys, zipfile
archive, base = sys.argv[1], sys.argv[2]
added = {}
for folder, _, files in os.walk(base):
    for name in files:
        path = os.path.join(folder, name)
        added[os.path.relpath(path, base).replace(os.sep, "/")] = path
entries = []
if os.path.exists(archive):
    with zipfile.ZipFile(archive) as z:
        entries = [(i.filename, z.read(i)) for i in z.infolist() if i.filename not in added and not i.is_dir()]
for name in sorted(added):
    with open(added[name], "rb") as f:
        entries.append((name, f.read()))
with zipfile.ZipFile(archive + ".tmp", "w", zipfile.ZIP_DEFLATED) as z:
    for name, data in entries:
        info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        z.writestr(info, data)
os.replace(archive + ".tmp", archive)
PY
}

# MARK: Up to date?

if [ ! -f "$SRC/go.mod" ] || [ ! -d "$SRC/libsharing" ]; then
  if [ -f "$OUT" ] && [ "$FORCE" = 0 ]; then
    echo "No Open Screen Sharing checkout at $SRC: keeping the aosgo.aar there is." >&2
    exit 0
  fi
  echo "No Open Screen Sharing checkout at $SRC (set OSS_SOURCE). Source: https://github.com/nekohasekai/open-screen-sharing" >&2
  exit 1
fi
# Which source this is (for the license's "corresponding source"): Open Screen Sharing's branch and commit, both
# patches, Tailnet's files that go into the library (not its tests and programs), the tools and this script.
HEAD_REF=$(sed -n 's/^ref: //p' "$SRC/.git/HEAD" 2>/dev/null || true)
COMMIT=$(cat "$SRC/.git/$HEAD_REF" 2>/dev/null || cat "$SRC/.git/HEAD" 2>/dev/null || echo unknown)
GOMOBILE_VERSION=$(awk '$1 == "github.com/sagernet/gomobile" { print $2 }' "$SRC/go.mod")
TAILNET_FILES=$(cd "$TAILNET" && find . -path ./cmd -prune -o -path ./internal -prune -o -path ./tailnetkit -prune -o \
  -type f \( -name '*.go' -o -name go.mod -o -name go.sum -o -name build.sh \) ! -name '*_test.go' -print | LC_ALL=C sort)
TAILNET_HASH=$(cd "$TAILNET" && echo "$TAILNET_FILES" | while read -r f; do shasum -a 256 "$f"; done | shasum -a 256 | cut -d' ' -f1)
# One Go for every step: the newer of the two modules' go lines (Tailnet's, so far), fetched once as
# golang.org/toolchain if it isn't the installed one.
GO_VERSION=$(printf '%s\n' "$(awk '$1 == "go" { print $2 }' "$SRC/go.mod")" "$(awk '$1 == "go" { print $2 }' "$TAILNET/go.mod")" |
  sort -V | tail -1)
export GOTOOLCHAIN="go$GO_VERSION"
STAMP="open-screen-sharing ${HEAD_REF#refs/heads/} $COMMIT, aOS patch $(shasum -a 256 "$AOS_PATCH" | cut -d' ' -f1)"
STAMP+=", Android patch $(shasum -a 256 "$ANDROID_PATCH" | cut -d' ' -f1)"
STAMP+=", Tailnet $TAILNET_HASH, Go $GO_VERSION, gomobile $GOMOBILE_VERSION, NDK $NDK_VERSION, API $MIN_API"
STAMP+=", script $(shasum -a 256 "$ROOT/Android/Tools/go-android.sh" | cut -d' ' -f1)"
if [ -f "$OUT" ] && [ "$FORCE" = 0 ] && [ "$(cat "$STAMP_FILE" 2>/dev/null || true)" = "$STAMP" ]; then
  exit 0
fi
if [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null || true)" ]; then
  echo "warning: $SRC has uncommitted changes; the stamp records only its commit" >&2
fi
echo "aosgo: Open Screen Sharing at $SRC (${HEAD_REF#refs/heads/} ${COMMIT:0:12}) with aOS's patches, and Tailnet/mobile"

for tool in gomobile gobind; do
  if ! go version -m "$GOBIN_DIR/$tool" 2>/dev/null |
    grep "mod[[:space:]]*github.com/sagernet/gomobile[[:space:]]*$GOMOBILE_VERSION" >/dev/null; then
    echo "$GOBIN_DIR/$tool isn't github.com/sagernet/gomobile $GOMOBILE_VERSION. Open Screen Sharing's 'make lib' installs it." >&2
    exit 1
  fi
done
# Tailnet/build.sh's build tags, read from there: the node offers nothing on the tailnet (tailnet.BuiltForAOS checks
# them at run time, NewNode refuses without).
TAGS=""
eval "$(grep -E '^TAGS\+?=' "$TAILNET/build.sh")"
[ -n "$TAGS" ] || { echo "no build tags in Tailnet/build.sh" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# MARK: Source and tests

"$TAILNET/build.sh" test >/dev/null
mkdir "$WORK/src"
cp -R "$SRC/go.mod" "$SRC/go.sum" "$SRC/libsharing" "$SRC/internal" "$WORK/src/"
patch -p1 -s -d "$WORK/src" < "$AOS_PATCH"
patch -p1 -s -d "$WORK/src" < "$ANDROID_PATCH"
# Tailnet joins Open Screen Sharing's module (one build, one Go runtime): a requirement with a replace to the folder,
# and a package that imports it and gomobile's bind so that 'go mod tidy' (which fills go.sum for every platform)
# keeps both. Go's version selection takes the newer of each module both need, so the patch's tests run again.
mkdir -p "$WORK/src/internal/aosbind"
cat > "$WORK/src/internal/aosbind/aosbind.go" <<'GO'
// aOS: keeps Tailnet/mobile and gomobile's bind in the module for the Android build (Android/Tools/go-android.sh).
package aosbind

import (
	_ "dev.marquart/aos/tailnet/mobile"
	_ "github.com/sagernet/gomobile/bind"
)
GO
(
  cd "$WORK/src"
  go mod edit -require=dev.marquart/aos/tailnet@v0.0.0-00010101000000-000000000000 \
    -replace=dev.marquart/aos/tailnet="$TAILNET" -go="$GO_VERSION"
  go mod tidy 2>&1 | grep -v '^go: \(downloading\|finding\|found\)' >&2 || true
  go list -tags "$TAGS" ./libsharing dev.marquart/aos/tailnet/mobile >/dev/null
  go test -count=1 -run AOS ./internal/rfb/ >/dev/null
)

# MARK: Build

(
  cd "$WORK/src"
  # Like Open Screen Sharing's own build (cmd/internal/build_libsharing), for Android, with Tailnet's tags.
  "$GOBIN_DIR/gomobile" bind -target android/arm64,android/amd64 -androidapi "$MIN_API" \
    -javapkg dev.marquart.aos -tags "$TAGS" -trimpath -buildvcs=false -ldflags "-s -w -buildid= -checklinkname=0" \
    -o "$WORK/aosgo.aar" ./libsharing dev.marquart/aos/tailnet/mobile
)
# The Android patch's Java class (DirectFramebuffer) into the aar's classes.jar and the sources jar.
JAVA_SRC="$WORK/src/android/java"
mkdir -p "$WORK/aar" "$WORK/classes"
unzip -q "$WORK/aosgo.aar" -d "$WORK/aar"
(cd "$JAVA_SRC" && find . -name '*.java' | LC_ALL=C sort > "$WORK/java-files")
(cd "$JAVA_SRC" && javac -nowarn -Xlint:-options -source 1.8 -target 1.8 -encoding UTF-8 -bootclasspath "$ANDROID_JAR" \
  -classpath "$WORK/aar/classes.jar" -d "$WORK/classes" @"$WORK/java-files")
zip_add "$WORK/aar/classes.jar" "$WORK/classes"
zip_add "$WORK/aosgo-sources.jar" "$JAVA_SRC"
rm -f "$WORK/aosgo.aar"
zip_add "$WORK/aosgo.aar" "$WORK/aar"

# MARK: Check

# Both ABIs, the JNI functions of both packages and the patch's, ELF segments aligned for 16 KB pages.
for abi in $ABIS; do
  so="$WORK/aar/jni/$abi/libgojni.so"
  [ -f "$so" ] || { echo "the aar has no jni/$abi/libgojni.so" >&2; exit 1; }
  symbols=$("$NDK_BIN/llvm-nm" -D --defined-only "$so")
  for symbol in Java_dev_marquart_aos_libsharing_DirectFramebuffer_address Java_dev_marquart_aos_libsharing_Session_connect \
    Java_dev_marquart_aos_tailnetkit_Node_dial; do
    grep " T $symbol\$" <<< "$symbols" >/dev/null || { echo "$abi/libgojni.so doesn't export $symbol" >&2; exit 1; }
  done
  if "$NDK_BIN/llvm-readelf" -lW "$so" | awk '$1 == "LOAD" { print $NF }' | grep -vE '^0x([4-9a-f]000|[0-9a-f]{5,})$' >/dev/null; then
    echo "$abi/libgojni.so has LOAD segments aligned below 16 KB" >&2
    exit 1
  fi
done

mkdir -p "$OUT_DIR"
mv -f "$WORK/aosgo.aar" "$OUT"
mv -f "$WORK/aosgo-sources.jar" "$OUT_DIR/aosgo-sources.jar"
echo "$STAMP" > "$STAMP_FILE"
echo "built $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
