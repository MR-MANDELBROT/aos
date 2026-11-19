#!/bin/bash
# Builds the Go library of aOS's desktop companion (Windows, Linux; macOS to test): aosgo as a C shared library per
# platform, under Android/third_party/aosgo-desktop/out/<os>-<arch>/ (not checked in; third_party/aosgo-desktop/README.md
# describes it). The same two packages as the Android app's aosgo.aar (Tools/go-android.sh), in one library with one Go
# runtime, behind a C API for JNA (third_party/aosgo-desktop/go/aosgo.h):
#
#   libsharing   Open Screen Sharing's Go library (GPL-3.0), copied from OSS_SOURCE (default
#                ~/Developer/open-screen-sharing, only read) with iOS/ThirdParty/OpenScreenSharing/libsharing-aos.patch,
#                third_party/libsharing-android.patch and third_party/aosgo-desktop/libsharing-desktop.patch
#   tailnetkit   aOS's Tailscale node (Tailnet/mobile), with Tailnet/build.sh's build tags
#
#   Android/Tools/go-desktop.sh                      build the targets that are missing or out of date
#   Android/Tools/go-desktop.sh --force              build them all again
#   Android/Tools/go-desktop.sh [--force] <target>...  only these: windows-amd64 windows-arm64 linux-amd64
#                                                    linux-arm64 darwin-arm64
#
# One target at a time. Windows and Linux are cross-compiled with zig as the C compiler (Linux for glibc 2.28 and
# later); macOS with Xcode's clang. The Go tests (Tailnet's, the patches', the wrapper's) run first. aosgo.source next to
# each library records what it was built from (the corresponding source: Open Screen Sharing's commit, the patches'
# hashes, the wrapper's and Tailnet's files, the toolchain and this script); a difference builds it again.
#
# Needs Go (it fetches the Go version the modules ask for once), zig (brew install zig) for Windows and Linux, Xcode's
# command line tools for macOS. Go's and zig's build caches for the cross builds are temporary (removed afterwards).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
THIRD="$ROOT/Android/third_party"
DESKTOP="$THIRD/aosgo-desktop"
OUT_ROOT="$DESKTOP/out"
AOS_PATCH="$ROOT/iOS/ThirdParty/OpenScreenSharing/libsharing-aos.patch"
ANDROID_PATCH="$THIRD/libsharing-android.patch"
DESKTOP_PATCH="$DESKTOP/libsharing-desktop.patch"
WRAPPER="$DESKTOP/go"
TAILNET="$ROOT/Tailnet"
SRC="${OSS_SOURCE:-$HOME/Developer/open-screen-sharing}"
ALL_TARGETS="windows-amd64 windows-arm64 linux-amd64 linux-arm64 darwin-arm64"
GLIBC=2.28

usage() { sed -n '2,24p' "$0" >&2; exit 2; }
FORCE=0
TARGETS=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    windows-amd64 | windows-arm64 | linux-amd64 | linux-arm64 | darwin-arm64) TARGETS+=" $arg" ;;
    *) usage ;;
  esac
done
TARGETS="${TARGETS:-$ALL_TARGETS}"

export PATH="/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$HOME/go/bin:$PATH"

library_name() { # <target>
  case "$1" in
    windows-*) echo aosgo.dll ;;
    linux-*) echo libaosgo.so ;;
    darwin-*) echo libaosgo.dylib ;;
  esac
}

# MARK: Up to date?

if [ ! -f "$SRC/go.mod" ] || [ ! -d "$SRC/libsharing" ]; then
  echo "No Open Screen Sharing checkout at $SRC (set OSS_SOURCE). Source: https://github.com/nekohasekai/open-screen-sharing" >&2
  exit 1
fi
HEAD_REF=$(sed -n 's/^ref: //p' "$SRC/.git/HEAD" 2>/dev/null || true)
COMMIT=$(cat "$SRC/.git/$HEAD_REF" 2>/dev/null || cat "$SRC/.git/HEAD" 2>/dev/null || echo unknown)
hash_files() { # <dir> <file list>: one hash over the files' hashes
  (cd "$1" && echo "$2" | while read -r f; do shasum -a 256 "$f"; done | shasum -a 256 | cut -d' ' -f1)
}
TAILNET_FILES=$(cd "$TAILNET" && find . -path ./cmd -prune -o -path ./internal -prune -o -path ./tailnetkit -prune -o \
  -type f \( -name '*.go' -o -name go.mod -o -name go.sum -o -name build.sh \) ! -name '*_test.go' -print | LC_ALL=C sort)
TAILNET_HASH=$(hash_files "$TAILNET" "$TAILNET_FILES")
WRAPPER_FILES=$(cd "$WRAPPER" && find . -type f \( -name '*.go' -o -name '*.h' \) ! -name '*_test.go' | LC_ALL=C sort)
WRAPPER_HASH=$(hash_files "$WRAPPER" "$WRAPPER_FILES")
GO_VERSION=$(printf '%s\n' "$(awk '$1 == "go" { print $2 }' "$SRC/go.mod")" "$(awk '$1 == "go" { print $2 }' "$TAILNET/go.mod")" |
  sort -V | tail -1)
export GOTOOLCHAIN="go$GO_VERSION"
SOURCE="open-screen-sharing ${HEAD_REF#refs/heads/} $COMMIT, aOS patch $(shasum -a 256 "$AOS_PATCH" | cut -d' ' -f1)"
SOURCE+=", Android patch $(shasum -a 256 "$ANDROID_PATCH" | cut -d' ' -f1)"
SOURCE+=", desktop patch $(shasum -a 256 "$DESKTOP_PATCH" | cut -d' ' -f1), wrapper $WRAPPER_HASH, Tailnet $TAILNET_HASH, Go $GO_VERSION"
SCRIPT_HASH=$(shasum -a 256 "$ROOT/Android/Tools/go-desktop.sh" | cut -d' ' -f1)

compiler() { # <target>: the C compiler's name and version, for the stamp
  case "$1" in
    darwin-*) echo "clang $(xcrun clang --version 2>/dev/null | head -1 | sed 's/.*version //; s/ .*//')" ;;
    *) echo "zig $(zig version 2>/dev/null || echo missing)" ;;
  esac
}
stamp() { # <target>
  local libc=""
  case "$1" in linux-*) libc=" glibc $GLIBC" ;; esac
  echo "$SOURCE, target $1$libc, $(compiler "$1"), script $SCRIPT_HASH"
}

STALE=""
for target in $TARGETS; do
  out="$OUT_ROOT/$target"
  if [ "$FORCE" = 1 ] || [ ! -f "$out/$(library_name "$target")" ] || [ ! -f "$out/aosgo.h" ] ||
    [ "$(cat "$out/aosgo.source" 2>/dev/null || true)" != "$(stamp "$target")" ]; then
    STALE+=" $target"
  fi
done
[ -n "$STALE" ] || exit 0

case "$STALE" in
  *windows-* | *linux-*) command -v zig >/dev/null || { echo "zig is missing (brew install zig)" >&2; exit 1; } ;;
esac
if [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null || true)" ]; then
  echo "warning: $SRC has uncommitted changes; the stamp records only its commit" >&2
fi
echo "aosgo-desktop:$STALE from Open Screen Sharing at $SRC (${HEAD_REF#refs/heads/} ${COMMIT:0:12}) with aOS's patches, and Tailnet/mobile"

# Tailnet/build.sh's build tags, read from there: the node offers nothing on the tailnet (NewNode refuses without).
TAGS=""
eval "$(grep -E '^TAGS\+?=' "$TAILNET/build.sh")"
[ -n "$TAGS" ] || { echo "no build tags in Tailnet/build.sh" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# MARK: Source and tests

"$TAILNET/build.sh" test >/dev/null
mkdir "$WORK/src"
cp -R "$SRC/go.mod" "$SRC/go.sum" "$SRC/libsharing" "$SRC/internal" "$WORK/src/"
patch -p1 -s -d "$WORK/src" < "$AOS_PATCH"
patch -p1 -s -d "$WORK/src" < "$ANDROID_PATCH"
patch -p1 -s -d "$WORK/src" < "$DESKTOP_PATCH"
# The wrapper (package main) joins Open Screen Sharing's module, and Tailnet with it (a requirement with a replace to
# the folder), as in the Android build: Go's version selection takes the newer of each module both need.
mkdir "$WORK/src/aosgo"
cp "$WRAPPER"/*.go "$WRAPPER"/aosgo.h "$WORK/src/aosgo/"
printf '// Generated by Android/Tools/go-desktop.sh.\n\npackage main\n\nfunc init() { source = `%s` }\n' "$SOURCE" \
  > "$WORK/src/aosgo/source.go"
(
  cd "$WORK/src"
  go mod edit -require=dev.marquart/aos/tailnet@v0.0.0-00010101000000-000000000000 \
    -replace=dev.marquart/aos/tailnet="$TAILNET" -go="$GO_VERSION"
  go mod tidy 2>&1 | grep -v '^go: \(downloading\|finding\|found\)' >&2 || true
  go test -count=1 -run AOS ./internal/rfb/ >/dev/null
  go test -count=1 -tags "$TAGS" ./aosgo >/dev/null
  for target in $STALE; do
    GOOS=${target%-*} GOARCH=${target#*-} CGO_ENABLED=0 go vet -tags "$TAGS" ./libsharing ./internal/rfb/media \
      dev.marquart/aos/tailnet/mobile
  done
)

# The check: every function of aosgo.h exported, and which system libraries the library needs (printed).
mkdir "$WORK/check"
cat > "$WORK/check/main.go" <<'GO'
// Checks a built aosgo library: it exports every function aosgo.h declares; prints the libraries it imports.
package main

import (
	"debug/elf"
	"debug/macho"
	"debug/pe"
	"encoding/binary"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
)

func main() {
	library, header := os.Args[1], os.Args[2]
	text, err := os.ReadFile(header)
	if err != nil {
		panic(err)
	}
	declared := regexp.MustCompile(`(?m)^[a-z_0-9 *]*\b(aosgo_[a-z_0-9]+)\(`).FindAllStringSubmatch(string(text), -1)
	exported, imported := map[string]bool{}, []string{}
	if f, err := elf.Open(library); err == nil {
		symbols, _ := f.DynamicSymbols()
		for _, s := range symbols {
			if s.Section != elf.SHN_UNDEF {
				exported[s.Name] = true
			}
		}
		imported, _ = f.ImportedLibraries()
		versions := map[string]bool{}
		if syms, err := f.ImportedSymbols(); err == nil {
			for _, s := range syms {
				if s.Version != "" {
					versions[s.Version] = true
				}
			}
		}
		for v := range versions {
			imported = append(imported, v)
		}
	} else if f, err := macho.Open(library); err == nil {
		for _, s := range f.Symtab.Syms {
			exported[strings.TrimPrefix(s.Name, "_")] = true
		}
		imported, _ = f.ImportedLibraries()
	} else if f, err := pe.Open(library); err == nil {
		exported = peExports(f)
		dlls := map[string]bool{}
		symbols, _ := f.ImportedSymbols() // "function:library" (ImportedLibraries isn't there for PE)
		for _, s := range symbols {
			if _, dll, found := strings.Cut(s, ":"); found {
				dlls[strings.ToLower(dll)] = true
			}
		}
		for dll := range dlls {
			imported = append(imported, dll)
		}
	} else {
		fmt.Fprintln(os.Stderr, "not an ELF, Mach-O or PE file:", library)
		os.Exit(1)
	}
	missing := 0
	for _, m := range declared {
		if !exported[m[1]] {
			fmt.Fprintln(os.Stderr, library, "doesn't export", m[1])
			missing++
		}
	}
	if missing > 0 || len(declared) == 0 {
		os.Exit(1)
	}
	sort.Strings(imported)
	fmt.Printf("%d functions; needs %s\n", len(declared), strings.Join(imported, " "))
}

// peExports reads the names in a PE file's export directory.
func peExports(f *pe.File) map[string]bool {
	var dir pe.DataDirectory
	switch h := f.OptionalHeader.(type) {
	case *pe.OptionalHeader64:
		dir = h.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_EXPORT]
	case *pe.OptionalHeader32:
		dir = h.DataDirectory[pe.IMAGE_DIRECTORY_ENTRY_EXPORT]
	}
	sections := map[*pe.Section][]byte{} // each section read once
	read := func(rva uint32, n uint32) []byte {
		for _, s := range f.Sections {
			if rva >= s.VirtualAddress && rva+n <= s.VirtualAddress+s.VirtualSize {
				data, found := sections[s]
				if !found {
					data, _ = s.Data()
					sections[s] = data
				}
				off := rva - s.VirtualAddress
				if int(off+n) <= len(data) {
					return data[off : off+n]
				}
			}
		}
		return nil
	}
	names := map[string]bool{}
	d := read(dir.VirtualAddress, 40)
	if d == nil {
		return names
	}
	count, table := binary.LittleEndian.Uint32(d[24:]), binary.LittleEndian.Uint32(d[32:])
	for i := uint32(0); i < count; i++ {
		entry := read(table+4*i, 4)
		if entry == nil {
			break
		}
		rva := binary.LittleEndian.Uint32(entry)
		var name []byte
		for j := uint32(0); ; j++ {
			c := read(rva+j, 1)
			if c == nil || c[0] == 0 {
				break
			}
			name = append(name, c[0])
		}
		names[string(name)] = true
	}
	return names
}
GO
(cd "$WORK/check" && go mod init aosgo/check >/dev/null 2>&1 && go build -o "$WORK/check-library" .)

# MARK: Build

# The cross builds' caches stay in WORK (removed on exit): Go's for the other platforms, zig's libc builds.
CROSS_GOCACHE="$WORK/gocache"
export ZIG_GLOBAL_CACHE_DIR="$WORK/zig-cache" ZIG_LOCAL_CACHE_DIR="$WORK/zig-cache"
for target in $STALE; do
  goos=${target%-*}
  goarch=${target#*-}
  name=$(library_name "$target")
  case "$target" in
    windows-amd64) cc="zig cc -target x86_64-windows-gnu" ;;
    windows-arm64) cc="zig cc -target aarch64-windows-gnu" ;;
    linux-amd64) cc="zig cc -target x86_64-linux-gnu.$GLIBC" ;;
    linux-arm64) cc="zig cc -target aarch64-linux-gnu.$GLIBC" ;;
    darwin-arm64) cc="$(xcrun --find clang) -isysroot $(xcrun --show-sdk-path)" ;;
  esac
  echo "  $target"
  build_cache="$CROSS_GOCACHE"
  [ "$goos" = darwin ] && build_cache="$(go env GOCACHE)"
  mkdir -p "$WORK/build/$target"
  (
    cd "$WORK/src"
    GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=1 CC="$cc" GOCACHE="$build_cache" \
      go build -buildmode=c-shared -tags "$TAGS" -trimpath -buildvcs=false \
      -ldflags "-s -w -buildid= -checklinkname=0" -o "$WORK/build/$target/$name" ./aosgo
  )
  needs=$("$WORK/check-library" "$WORK/build/$target/$name" "$WRAPPER/aosgo.h")
  out="$OUT_ROOT/$target"
  rm -rf "$out"
  mkdir -p "$out"
  mv -f "$WORK/build/$target/$name" "$out/$name"
  cp "$WRAPPER/aosgo.h" "$out/aosgo.h"
  stamp "$target" > "$out/aosgo.source"
  echo "    $out/$name ($(du -h "$out/$name" | cut -f1 | tr -d ' ')): $needs"
  rm -rf "$WORK/build/$target"
done
