# aOS desktop: the Go library (aosgo for Windows, Linux, macOS)

The desktop companion (Kotlin/JVM, Compose Multiplatform, Windows and Linux) uses the same Go code as the Android
app's `aosgo.aar` (`../README.md`): Open Screen Sharing's **libsharing** (the screen) and aOS's **tailnetkit** (the
Tailscale node, `Tailnet/mobile`), in **one** C shared library with one Go runtime, loaded with JNA.

| Platform | File | Built with |
|---|---|---|
| Windows x64, arm64 | `out/windows-amd64/aosgo.dll`, `out/windows-arm64/aosgo.dll` | zig cc (MinGW, UCRT) |
| Linux x64, arm64 | `out/linux-amd64/libaosgo.so`, `out/linux-arm64/libaosgo.so` | zig cc (glibc 2.28 and later) |
| macOS arm64 (to test) | `out/darwin-arm64/libaosgo.dylib` | Xcode's clang |

Checked in: this README, `go/` (the wrapper: `aosgo.h`, the C API; `main.go`, `session.go`, `tailnet.go`, the tests),
`kotlin/AosGo.kt` (the JNA binding), `libsharing-desktop.patch`, `.gitignore`. `out/` is built by
`Android/Tools/go-desktop.sh` and not checked in (like the aar). Each `out/<target>/` has the library, `aosgo.h` and
`aosgo.source` (what it was built from).

## Building

```sh
Android/Tools/go-desktop.sh                   # the targets that are missing or out of date (silent when up to date)
Android/Tools/go-desktop.sh linux-amd64       # only that one; --force builds again
```

Needs Go (the script pins the newer of the two modules' Go versions, like go-android.sh; Go fetches it once), zig for
Windows and Linux (`brew install zig`, 0.17.1 so far), Xcode's command line tools for macOS, and Open Screen Sharing's
checkout (`OSS_SOURCE`, default `~/Developer/open-screen-sharing`, only read). It runs Tailnet's tests, the patches'
tests (`go test -run AOS ./internal/rfb/`) and the wrapper's (`go/aosgo_test.go`: the header's constants are
libsharing's, JSON names, clipboard layout), `go vet` of libsharing and Tailnet/mobile for every target, then builds one
target at a time:

```sh
GOOS=<os> GOARCH=<arch> CGO_ENABLED=1 CC="zig cc -target <x86_64|aarch64>-<windows-gnu|linux-gnu.2.28>" \
  go build -buildmode=c-shared -tags <Tailnet/build.sh's tags> -trimpath -buildvcs=false \
  -ldflags "-s -w -buildid= -checklinkname=0" ./aosgo
```

and checks that every function of `aosgo.h` is exported (ELF dynamic symbols, the PE export table, Mach-O) and prints
what the library imports. Go's and zig's caches for the cross builds live in the script's temporary folder (a full cross
build fills about 0.8 GB of Go cache per target), so nothing stays behind but the output.

Result (2026-11-19): `aosgo.dll` 24 MB (x64) and 22 MB (arm64), `libaosgo.so` 30 MB (x64) and 28 MB (arm64),
`libaosgo.dylib` 22 MB; 62 functions each. What they need: Windows `kernel32.dll` and the Universal CRT
(`api-ms-win-crt-*`, part of Windows 10 and later), nothing to ship; Go loads the rest of Windows itself. Linux
`libc.so.6`, `libpthread.so.0`, `libresolv.so.2` (glibc symbol versions up to 2.3.2 on x64, 2.17 on arm64: any glibc
distribution of the last ten years; not musl/Alpine).

### Why a patch for Windows

`libsharing-desktop.patch` (GPL-3.0, after aOS's and the Android patch): the high performance stream's UDP code
(`internal/rfb/media/socket.go`) uses Unix socket calls and doesn't compile for Windows, and sing (its network library)
has batched UDP reads and writes only on Linux, NetBSD and Apple's systems. `socket_windows.go` does the same with
Winsock, one datagram per read and write. Linux and macOS are unchanged. Everything else of libsharing and tsnet builds
for Windows and Linux as it is. Not tested on Windows yet: high performance there (Windows doesn't report "port
unreachable" for UDP like the others; a refused stream ends by silence instead).

## The C API (go/aosgo.h)

`aosgo.h` documents every function; the gist:

- **Handles** (`int64_t`, > 0) for sessions and nodes. Failing calls return -1 or NULL and put a message into
  `char **error` (free it with `aosgo_free`, like every string the library returns). Strings are UTF-8.
- **Sessions** (`aosgo_session_*`): new (options as JSON with the gomobile names: `host`, `port`, `username`,
  `password`, `loginType`, `requireTrustedKey`, `trustedFingerprint`, ...), connect, disconnect, abort, free, attach
  framebuffer, input (pointer, scroll, scroll phase, momentum, magnify, rotate, key, key code, text, paste, system
  commands, assist cursor), clipboard (as text or the full item/flavor structure), virtual display, quality, mode,
  visibility, refresh, prompts, statistics, high performance (options as JSON), keyframes, file transfer, drag and drop,
  `aosgo_check_login`, `aosgo_probe_server`.
- **Events**: one callback per session, `fn(session, kind, a, b, c, d, e, text, data, length)`: `AOSGO_EVENT_*` are
  Android's 25 SessionHandler methods; numbers in `a`..`e`, strings or JSON (server info, displays, access unit
  details) in `text`, bytes (cursor pixels, clipboard, parameter sets, access units, audio) in `data`. Pointers are
  valid only during the callback.
- **Tailnet** (`aosgo_tailnet_*`): built_for_aos, is_sign_in_page, new (with a log callback), start (with a state
  callback), state (JSON), status_json, login, logout, dial (to a one-time 127.0.0.1 port, optionally only for your
  client port), close.
- **Log**: `aosgo_set_log_handler(fn, minimum_level)` for libsharing's log.

Callbacks come on Go threads, one at a time per session in order (media from the stream's threads); they may call back
into the library. Calls may come from any thread; network calls block.

### The framebuffer

`aosgo_session_attach_framebuffer(session, address, width, height, bytes_per_row)` takes any memory the app owns: a JNA
`Memory` (the binding's `Framebuffer`), or a Skia `Pixmap`'s address to draw straight into a Compose `Bitmap`
(BGRA_8888 matches: libsharing writes B, G, R, X; draw opaque). Rules (as on Android):

1. `FRAMEBUFFER_RESIZE (w, h)` comes before the first picture and on every size change. Attach a framebuffer of exactly
   that size **inside** the callback, or the session fails.
2. After `FRAMEBUFFER_UPDATE (x, y, w, h)` that rectangle is complete. libsharing may already write the next one while
   you read (take what's there; the next update repairs it).
3. libsharing writes into the memory until another framebuffer was attached **and** that resize callback returned, or
   until the session's `DISCONNECTED` event. Keep it valid until then. The Kotlin binding keeps its `Framebuffer`s
   referenced exactly that long; don't `close()` one before that.
4. Outside a resize (connected) an attach replaces the framebuffer at once; before connecting it fails.

## The Kotlin binding (kotlin/AosGo.kt)

Package `dev.marquart.aos.desktop.native`; needs `net.java.dev.jna:jna` (5.19.1 in `gradle/libs.versions.toml`) and
`kotlinx-serialization-json` (just its JSON tree). Copy it into the desktop module or add the folder as a source dir.
The library is loaded as `aosgo` from `jna.library.path`, or from the absolute path in the system property
`aosgo.library` (set it to the file the app ships, e.g. next to the jar).

```kotlin
val session = AosGoSession(SessionOptions(host = mac, port = 5900, username = user, password = pw,
    platform = Libsharing.PlatformMac, keepAlive = true), object : SessionHandler {
    override fun onFramebufferResize(session: AosGoSession, width: Int, height: Int) {
        val fb = Framebuffer(width, height)          // or attachFramebuffer(pixmapAddress, w, h, rowBytes)
        session.attachFramebuffer(fb)
        screen.show(fb)
    }
    override fun onFramebufferUpdate(update: FramebufferUpdate) = screen.invalidate(update)
    override fun onStateChanged(state: Int, errorCode: Int, message: String) { ... }
})
session.connect()

val node = TailnetNode(dir, "aos-<device>", "") { line -> log(line) }
node.start { state -> if (state.needsLogin && TailnetNode.isSignInPage(state.authURL)) openBrowser(state.authURL) }
val socket = Socket().apply { bind(InetSocketAddress(loopback, 0)) }
socket.connect(InetSocketAddress(loopback, node.dial(macHost, 22, 15_000, socket.localPort)))
```

Names follow the Android library (`Libsharing.StateConnected`, `onVideoAccessUnit`, `TailnetState.authURL`, ...), so the
Android app's `LibsharingSession.kt` ports almost line by line. One JNA callback serves all sessions and stays attached
to the VM (daemon threads named `aosgo-*`); handler exceptions are caught and printed.

## Tests (2026-11-19, on this Mac)

- Go: Tailnet's tests, the patches' AOS tests, the wrapper's tests (in the script).
- JVM (JDK 17, JNA 5.19.1, the binding as is) with `out/darwin-arm64/libaosgo.dylib`: libsharing against a small RFB
  server (RFB 3.8, no authentication, 64x32): checkLogin, connect, server info, the picture in the framebuffer
  (B 0x33, G 0x22, R 0x11), pointer, key, text, clipboard both ways, statistics, disconnect, free while running;
  tailnetkit against `Tailnet/build.sh testnet`: sign-in, Running, dial by address and MagicDNS name and back, another
  socket turned away, nothing on other ports, sign-out, close.
- Windows and Linux: built, every function exported, imports as above. Not run yet (no Windows or Linux machine
  used); the first run belongs in the Windows VM (`~/VMs/Windows`) or on a Linux box.

## Licenses

As for the aar (`../README.md`, "Licenses"): **libsharing is GPL-3.0** with Open Screen Sharing's extra term, so the
wrapper (`go/`, `kotlin/AosGo.kt`, the patch, all GPL-3.0) and **every built library is GPL-3.0 as a whole**, and so is
a desktop app that ships it: the author's consent before giving it to anyone else, the source offered
(`aosgo.source` names it: Open Screen Sharing's commit, the patches, the wrapper's and Tailnet's files), and the
acknowledgements showing Open Screen Sharing's LICENSE and COPYING (`iOS/ThirdParty/OpenScreenSharing/`) and
Tailscale's BSD-3-Clause license. The Windows DLL links zig's MinGW-w64 startup code (permissive, public domain/ZPL
parts) and uses the system's UCRT; the Linux library links glibc dynamically (LGPL).
