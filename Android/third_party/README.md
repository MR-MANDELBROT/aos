# aOS for Android: the Go library

The Android app's Go code is one library, `aosgo/aosgo.aar` (with `aosgo-sources.jar`), built by
`Android/Tools/go-android.sh` and not checked in (like the iPhone's xcframeworks; `.gitignore` here). It holds two
packages:

| Java package | From | What |
|---|---|---|
| `dev.marquart.aos.libsharing` | Open Screen Sharing's Go library (GPL-3.0), Max's fork `~/Developer/open-screen-sharing`, branch `autofill-passwort`, with `iOS/ThirdParty/OpenScreenSharing/libsharing-aos.patch` and `libsharing-android.patch` (here) | the screen: RFB session, framebuffer, input, clipboard, high performance video |
| `dev.marquart.aos.tailnetkit` | aOS's `Tailnet/mobile` (on `Tailnet/`, tsnet from tailscale.com v1.104.5) | aOS's own Tailscale node: sign-in, state, dialing the Mac |

Checked in: this README, `libsharing-android.patch`, `.gitignore`, the script, and the Go sources in `Tailnet/mobile`.

## Why one library, not two

The iPhone app has two Go libraries (Libsharing.xcframework from gomobile, Tailnetkit as a C archive). On Android that
does not work, for two reasons, both seen:

- **One TLS slot for every Go runtime.** On Android 10 and later the Go runtime keeps its goroutine pointer in the
  fixed thread-local slot `TLS_SLOT_APP` (Go's `runtime/cgo/gcc_android.c`); on the iPhone each runtime finds a slot
  of its own. Two Go libraries in one Android process share that slot, so a thread that calls into both (the main
  thread, any Kotlin dispatcher thread) crashes. In the emulator: `fatal error: addspecial on invalid pointer` on the
  first call into the second library after a call into the first.
- **gomobile's Java classes.** Every gomobile library brings `go.Seq`, `go.Universe`, ... and loads its own `.so`
  from them; two of them can't be in one app (duplicate classes).

So the script binds both packages in one `gomobile bind`: one `libgojni.so`, one Go runtime. Tailnet joins Open Screen
Sharing's Go module for that build (a `replace` to `Tailnet/`); Go's version selection takes the newer of each shared
dependency. That moves a few of libsharing's dependencies by minor versions (golang.org/x/crypto, x/sys, x/net,
x/text, x/sync, x/exp, fsnotify, vishvananda/netns, mdlayher/socket, go4.org/netipx); aOS's libsharing tests run
again with them.

## Licenses

- **libsharing: GPL-3.0** with Open Screen Sharing's extra term ("no derivative work may use the name or imply
  association with this application without prior consent"). The texts: `iOS/ThirdParty/OpenScreenSharing/LICENSE`
  (the notice and the extra term) and `COPYING` (GPL-3.0). aOS's changes (both patches, marked `aOS:`) are GPL-3.0
  too. Since the library holds libsharing, **`aosgo.aar` as a whole is GPL-3.0**, and so is an app that ships it (the
  same situation as the iPhone app, iOS/NOTES.md "The screen"): before giving the app to anyone else, the author's
  consent, and the source offered. The corresponding source of a build is in `aosgo/aosgo.source` (Open Screen
  Sharing's commit, both patches' hashes, Tailnet's file hash).
- **Tailscale (tailscale.com): BSD-3-Clause.** `Tailnet/mobile/interfaces_android.go` is Tailscale's
  `feature/androidbin` code (BSD-3-Clause).
- Go and gomobile (github.com/sagernet/gomobile, the fork Open Screen Sharing pins): BSD-3-Clause.

The app's acknowledgements must show Open Screen Sharing's LICENSE and COPYING and Tailscale's license, like the
iPhone's Settings > Acknowledgements.

## Building

```sh
Android/Tools/go-android.sh            # builds aosgo.aar if it's missing or out of date (silent when up to date)
Android/Tools/go-android.sh --force    # builds it again
```

What it needs (it installs nothing; Go may fetch modules once):

- Go, and gomobile plus gobind from `github.com/sagernet/gomobile` at the version in Open Screen Sharing's go.mod
  (v0.1.13; its `make lib` installs them into `~/go/bin`). The build uses the newer of the two modules' Go versions
  (Tailnet's, go1.27.3; Go fetches that toolchain once).
- A JDK (`JAVA_HOME`, default `/opt/homebrew/opt/openjdk@17`).
- The Android SDK (`ANDROID_HOME`, default `/opt/homebrew/share/android-commandlinetools`) with a platform
  (android-36 now) and the NDK (`ANDROID_NDK_HOME`, default the newest in `$ANDROID_HOME/ndk`; installed:
  `ndk;30.0.16248370`).
- Open Screen Sharing's checkout (`OSS_SOURCE`, default `~/Developer/open-screen-sharing`); it is only read. Without
  it the script keeps an existing aar.

What it does: runs Tailnet's tests (`Tailnet/build.sh test`), copies Open Screen Sharing's Go module, applies both
patches, adds Tailnet, runs aOS's libsharing tests (`go test -run AOS ./internal/rfb/`), then

```sh
gomobile bind -target android/arm64,android/amd64 -androidapi 29 -javapkg dev.marquart.aos -tags <Tailnet/build.sh's tags> \
  -trimpath -buildvcs=false -ldflags "-s -w -buildid= -checklinkname=0" ./libsharing dev.marquart/aos/tailnet/mobile
```

compiles the patch's Java class (`DirectFramebuffer`) into `classes.jar`, and checks the result: both ABIs, the JNI
functions of both packages, ELF segments aligned for 16 KB pages (0x4000).

The build tags are Tailnet/build.sh's (read from there): the node offers nothing on the tailnet (no peer API, Taildrop,
Tailscale SSH, web client, ...); `Tailnetkit.builtForAOS()` reports it and `newNode` refuses a build without them.

Result (2026-11-19): `aosgo.aar` 21 MB; `libgojni.so` 26 MB (arm64-v8a) and 29 MB (x86_64) uncompressed; minSdk 29.

### In Gradle

```kotlin
dependencies { implementation(files("../third_party/aosgo/aosgo.aar")) }   // in the app module (path relative to it)
android { defaultConfig { ndk { abiFilters += listOf("arm64-v8a", "x86_64") } } }
```

A library module can't build an aar that depends on a local aar file, so the app module takes it. The aar's
`proguard.txt` keeps `go.**` and `dev.marquart.aos.**` (needed: Go calls Java methods by name). The app needs
`android.permission.INTERNET`.

## The Kotlin-facing API

gomobile's rules: Go structs become Java classes with `getX()`/`setX()` per field; `[]byte` arrives as a new
`byte[]` (a copy on every getter call: call `getData()` once); Go `error` results become `throws Exception`; Go
interfaces become Java interfaces the app implements. Go objects behind Java objects live as long as the Java object.

### libsharing (dev.marquart.aos.libsharing)

The same API as the iPhone's (`Libsharing*` in Swift), so OSS's iOS session code is the reference
(`iOS/ThirdParty/OpenScreenSharing/Sources/Session/LibsharingSession.swift`). The main parts:

```java
// Libsharing (package functions and constants)
static SessionOptions newSessionOptions();                 // defaults: ProtocolRFB, LoginAccount, QualityAdaptive, ModeControl
static Session newSession(SessionOptions, SessionHandler) throws Exception;
static HighPerformanceOptions newHighPerformanceOptions();  // HEVC, audio on, 1 band
static void setLogHandler(LogHandler, int minimumLevel);   // slog levels: -4 debug, 0 info, 4 warn, 8 error
// constants: StateConnecting 1, StateAuthenticating 2, StateWaitingForApproval 3, StateChoosingSession 4,
// StateConnected 5, StateDisconnected 6; Error*, Login*, Quality*, Mode*, Codec*, DecoderCodec*, VideoMode*, ...

// SessionOptions: host, port, username, password, trustedFingerprint, requireTrustedKey (aOS), allowUnverifiedLogin,
// loginType, quality, mode, sharedClipboard, clientName, platform, decoderMaxPixelRate, maximumFrameRate (0/30/60),
// updateRate, keepAlive, disableUDP, cacheDirectory, audio, microphone, keyboardLayout (getX/setX each)

// Session
void connect() throws Exception;          // returns at once; progress comes through onStateChanged
void disconnect();  void abort();
void attachFramebuffer(long address, int width, int height, int bytesPerRow) throws Exception;   // see DirectFramebuffer
void sendPointer(int x, int y, int buttons, int clickCount) throws Exception;
void sendScroll(int x, int y, double dx, double dy) throws Exception;
void sendKey(int keysym, boolean down) throws Exception;
void sendKeyCode(int keyCode, int keyboardType, int keysym, boolean down) throws Exception;
void sendText(String) / pasteText(String) / setClipboard(Clipboard) / requestClipboard() ...
void setVirtualDisplay(int width, int height, double density, int maximumWidth, int maximumHeight) throws Exception;
void startHighPerformance(HighPerformanceOptions) / restartHighPerformance(...) / requestKeyframe() throws Exception;
void setQuality(int) / setMode(int) / setVisible(boolean) / requestRefresh() ... throws Exception;

// SessionHandler (the app implements all 25)
void onStateChanged(int state, int errorCode, String message);
void onServerInfo(ServerInfo); void onServerCertificate(String fingerprint);
void onFramebufferResize(int width, int height); void onFramebufferUpdate(FramebufferUpdate);
void onCursorImage(CursorImage); void onCursorPosition(int x, int y);
void onVideoFormat(VideoFormat); void onVideoAccessUnit(VideoAccessUnit);
void onAudioFormat(AudioFormat); void onAudioPacket(AudioPacket); void onMicrophone(AudioFormat);
void onMediaStopped(int errorCode, String message);
void onDisplays(DisplayList); void onClipboard(Clipboard); void onClipboardProblem(int, String); void onBell();
void onKeyboardSource(String, boolean); void onStatus(int); void onPrompt(Prompt); void onDeviceInfo(String, String, String);
void onFileTransferProgress(long, long, long); void onFileTransferFinished(long, String, int, String);
void onDropDestination(long, String); void onRemoteDrag(RemoteDrag);
```

`javap -cp classes.jar` on the aar's classes.jar lists everything; `aosgo-sources.jar` has the generated Java.

### The framebuffer (standard mode): DirectFramebuffer

The iPhone hands libsharing the address of a CVPixelBuffer. Java has no pointers, so aOS's Android patch adds
`dev.marquart.aos.libsharing.DirectFramebuffer`: a direct `ByteBuffer` whose address a JNI function in the library
reads. libsharing writes the remote screen straight into it: no copy, nothing per frame from Kotlin.

```java
public final class DirectFramebuffer {
    public final int width, height, bytesPerRow;   // bytesPerRow = 4 * width
    public final java.nio.ByteBuffer pixels;       // direct, capacity bytesPerRow * height, zero at first
    public DirectFramebuffer(int width, int height);
    public void attachTo(Session session) throws Exception;   // session.attachFramebuffer(address, ...)
}
```

The contract:

1. `onFramebufferResize(w, h)` comes (on the session's Go thread) before the first picture and on every size change.
   **Inside that callback**, before returning: `fb = DirectFramebuffer(w, h); fb.attachTo(session)`. If nothing was
   attached when it returns, the session fails ("no WxH framebuffer was attached during OnFramebufferResize").
2. Pixels: 4 bytes each, memory order **B, G, R, X**; X is undefined (padding from the server, sometimes 0): draw
   opaque. Rows `bytesPerRow` apart, top row first.
3. `onFramebufferUpdate(u)`: the rectangle `u.getX(), getY(), getWidth(), getHeight()` is complete in the buffer. The
   renderer uploads it, e.g. GLES `glTexSubImage2D` of that rectangle as `GL_RGBA`/`GL_UNSIGNED_BYTE` with
   `GL_UNPACK_ROW_LENGTH = width` and a `.bgra` swizzle in the shader (or `GL_BGRA_EXT` where the extension is
   there). `android.graphics.Bitmap` (`ARGB_8888` is R,G,B,A in memory) would need the channels swapped. libsharing
   keeps writing while the renderer reads (like on the iPhone): take what's there, the next update repairs it.
4. Lifetime: keep a strong reference to the attached DirectFramebuffer until another one was attached (the next
   resize) **and** that callback returned, or until `onStateChanged(StateDisconnected, ...)`. Its memory goes with
   the object; libsharing would write into freed memory otherwise.
5. `attachTo` outside a resize (a connected session) replaces the framebuffer at once; before connecting it fails
   with "not connected".

Tested in the emulator: a plain RFB server's 64x32 picture arrived in the buffer as B 0x33, G 0x22, R 0x11.

The cursor comes separately: `onCursorImage` (width, height, hotspot, `getPixels()` 4 bytes per pixel in libsharing's
BGRA order, `getInvert()`; see OSS's `CursorTheme.swift`/`StandardCursor.swift` for how the iPhone draws it) and
`onCursorPosition`.

### High performance: encoded video for MediaCodec

High performance (Apple's media stream: HEVC or H.264 over SRTP/UDP, needs the direct path to the Mac, no SSH
tunnel; iOS/NOTES.md "High performance: ports and protocols") delivers encoded video instead of framebuffer updates.

Starting it (after `connect()`, or before: libsharing keeps it until connected):

```kotlin
val hp = Libsharing.newHighPerformanceOptions()
hp.supportedCodecs = Libsharing.DecoderCodecHEVC or Libsharing.DecoderCodecH264   // what MediaCodecList decodes in hardware
hp.pixelFormats = (1 shl 0) or (1 shl 1)   // 4:2:0 8 bit (full and video range); 4:4:4 (bits 3, 4) only with an HEVC
                                           // RExt 4:4:4 hardware decoder, 10 bit 4:4:4 HDR (bit 5) likewise
hp.bands = 1                               // one picture per frame (see bands below)
hp.videoMode = Libsharing.VideoModeCoreDevice   // the iPhone: CoreDevice on the internet/tailnet, RemoteDesktop on the LAN
hp.audio = false                           // until the app plays AAC (onAudioFormat/onAudioPacket)
session.startHighPerformance(hp)
```

`ServerInfo.getSupportsHighPerformance()` says whether the Mac offers it. `SessionOptions.decoderMaxPixelRate`
(pixels per second the decoder manages; 0 = unknown) lets libsharing pick 30 instead of 60 frames a second for large
virtual displays.

The callbacks, in this order, on the media stream's Go thread (one at a time):

1. **`onVideoFormat(f)`** before the first access unit and again whenever the stream changes (new parameter sets,
   bands, HDR). Then (re)configure the decoder.
   - `f.getCodec()`: `Libsharing.CodecHEVC` (1) → `video/hevc`, `CodecH264` (2) → `video/avc`.
   - Parameter sets: `f.len()` of them, `f.get(i)` each a **raw NAL unit, no start code, no length prefix**, in stream
     order (HEVC: VPS, SPS, PPS; H.264: SPS, PPS).
   - `f.getHeight()`: the whole picture's height (the canvas, all bands); the width comes from the SPS (MediaCodec
     reads it from csd; give `MediaFormat` the virtual display's size as a hint).
   - `f.getChromaFormat()`: 1 = 4:2:0, 3 = 4:4:4. `f.getHDR()`: 10 bit HDR (only if requested).
   - MediaCodec: HEVC: `csd-0` = all parameter sets, each with `00 00 00 01` in front, in one buffer. H.264: `csd-0` =
     `00 00 00 01` + SPS, `csd-1` = `00 00 00 01` + PPS. (Or queue that as the first input buffer with
     `BUFFER_FLAG_CODEC_CONFIG`.)
2. **`onVideoAccessUnit(u)`** per access unit:
   - `u.getData()`: the access unit as **length-prefixed NAL units** (each: 4 byte big-endian length, then the NAL unit;
     AVCC/HVCC style with NALU length size 4), **without parameter sets** (those only come with onVideoFormat). For
     MediaCodec (Annex B) replace each 4 byte length with `00 00 00 01` in place: same size, one pass:
     `var i = 0; while (i + 4 <= d.size) { val n = (d[i].toInt() and 0xff shl 24) or (d[i+1].toInt() and 0xff shl 16) or (d[i+2].toInt() and 0xff shl 8) or (d[i+3].toInt() and 0xff); d[i]=0; d[i+1]=0; d[i+2]=0; d[i+3]=1; i += 4 + n }`.
   - `u.getSync()`: a random access point (HEVC IRAP, H.264 IDR) → `BUFFER_FLAG_KEY_FRAME`. After a format change, a
     discontinuity or a decoder error, feed nothing until a sync unit.
   - `u.getTimestamp()` / `u.getClockRate()`: presentation time in clock ticks (a continuous 64 bit count) and the
     clock (24000 Hz): `presentationTimeUs = timestamp * 1_000_000 / clockRate`.
   - `u.getDiscontinuity()`: units were lost: `flush()` the decoder and wait for a sync unit; call
     `session.requestKeyframe()` when stuck (the iPhone does it on every decoder failure).
   - `u.getFrameID()`, `getFrameEnd()`, `getBand()`, `getBands()`, `getChangedBands()`: frame assembly for bands.
     With `bands = 1` every unit is a whole frame (`frameEnd` true, `band` 0).
   - `u.getTurns()`: the picture's rotation in quarter turns (the iPhone's `PictureTurns`): turn when drawing.
   - `getHoldNanoseconds()`, `getComposed()`, `getComposeNanoseconds()`: timing for statistics.
3. **`onMediaStopped(errorCode, message)`**: the stream ended (`MediaErrorBusy`, `Refused`, `Silent`, `Network`);
   fall back (the iPhone hands over to the SSH tunnel, standard mode).

Bands: on the local network the iPhone asks for 4 bands (horizontal strips of `height / 4`, each its own SSRC,
decoded by one VideoToolbox session and stacked: `top = band * stripHeight`), with 4:4:4. Android hardware decoders
rarely do HEVC 4:4:4; start with `bands = 1` and 4:2:0 everywhere (what the iPhone uses on the internet).

Audio (if `hp.audio`): `onAudioFormat` (`getFormatID()` a Core Audio format id, sample rate, channels, frames per
packet, `getMagicCookie()`), then `onAudioPacket` (`getData()`, `getTimestamp()`, `getLost()`).

### tailnetkit (dev.marquart.aos.tailnetkit)

The Android counterpart of the iPhone's `EmbeddedTailnet` + `TailnetNodeBox` (iOS/Sources/Tailnet/EmbeddedTailnet.swift).

```java
// Tailnetkit (package functions)
static boolean builtForAOS();
static boolean isSignInPage(String url);     // https and tailscale.com / *.tailscale.com: only those open
static Node newNode(String dir, String hostname, String controlURL, Logger logger) throws Exception;
    // dir: absolute, out of backups, e.g. noBackupFilesDir/Tailnet (created 0700); hostname: DNS label, aOS uses
    // "aos-<device name>" (TailnetNames on the iPhone); controlURL: "" = Tailscale's server; logger: null or a sink
    // for the node's verbose log (URLs already replaced by "<url>")

// Node (methods block: call them off the main thread)
void start(Listener listener) throws Exception;   // doesn't wait; null listener allowed; a second start does nothing
State state() throws Exception;
String statusJSON() throws Exception;             // `tailscale status --json`, what the iPhone's TailnetStatus parses
void login() throws Exception;                    // asks for a new sign-in URL (comes with the next state)
void logout() throws Exception;                   // leaves the tailnet; then close() and delete dir
int dial(String host, int port, int timeoutMillis, int clientPort) throws Exception;   // see below
void close();                                     // idempotent, also from inside the listener

interface Listener { void onState(State state); }
interface Logger { void log(String line); }

// State
String getBackendState();   // NoState, NeedsLogin, NeedsMachineAuth, Stopped, Starting, Running
boolean isRunning(); boolean needsLogin();
String authURL();           // the sign-in page while needed, else "" (a method on purpose: toString() leaves it out)
String getTailnet(); String getMagicDNSSuffix(); String getDNSName();   // own MagicDNS name, no final dot
String getAddresses();      // own tailnet addresses, comma-separated, IPv4 first
String getKeyExpiry();      // RFC 3339 or ""
String getHealth();         // Tailscale's health problems, one per line
String getError();          // last critical message, or ""
```

The iPhone's flow maps to it: set up → `newNode` + `start(listener)`; while `needsLogin()` and `authURL()` passes
`isSignInPage`, open it in a Custom Tab (the iPhone uses ASWebAuthenticationSession; Tailscale's page doesn't lead
back, so close it once a state with `isRunning()` arrives); if no URL comes, `login()`. Sign out: `logout()`,
`close()`, delete the folder. The node runs as long as the app keeps it; on the iPhone it starts with the app.

Dialing the Mac (its tailnet address or MagicDNS name, port 22): the node can't hand a socket to the JVM, so
`dial` connects through the tailnet and then listens once on `127.0.0.1` and returns that port: one connection within
15 seconds, then the listener closes (without a connection, the tailnet connection closes too). With `clientPort > 0`
it takes only a connection from that local port, so no other app on the phone can take it. The safe way:

```kotlin
val loopback = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
val socket = Socket()
socket.bind(InetSocketAddress(loopback, 0))                       // our port first
val port = node.dial(macHost, 22, 15_000, socket.localPort)        // blocks until the tailnet connection stands
socket.connect(InetSocketAddress(loopback, port), 5_000)
socket.tcpNoDelay = true
// hand `socket` to the SSH library (a SocketFactory returning it, or the library's "connect via socket" API)
```

The host key check stays the app's (the iPhone pins the Mac's host key from pairing, whatever the route).

Android specifics in the node: Android denies apps the netlink socket that Go's `net.Interfaces` needs, so the node
reports one synthetic interface with the addresses the kernel would send from (Tailscale's own androidbin
approach); magicsock finds the phone's endpoints with that. DNS goes through bionic (cgo resolver). Tested in the
emulator against aOS's test tailnet (`Tailnet/build.sh testnet`, reached through `adb reverse`): sign-in, Running
with addresses and MagicDNS name, dial to the "Mac" node's port 22 and back, another socket turned away, sign-out
back to NeedsLogin. Not yet tested: a real tailnet (Tailscale's server, DERP over the internet, a phone on mobile
data), and Android's background limits (the node stops with the process).

## Threads

- Every callback from Go (`SessionHandler`, `LogHandler`, `Listener`, `Logger`) runs on a **Go thread** that gomobile
  attaches to the VM (named `Thread-N`), never on the main thread. Post UI work to the main thread.
- A callback blocks the goroutine that called it. libsharing's session callbacks (state, resize, framebuffer updates,
  cursor, clipboard, prompts) come in order from the session's goroutine: a slow `onFramebufferUpdate` slows the
  picture. Video and audio come from the media stream's goroutines: hand the data to the decoder's thread and
  return (MediaCodec's `dequeueInputBuffer` with a short timeout, or a queue).
- `onFramebufferResize` must attach the framebuffer before it returns (above); `onPrompt` waits for
  `session.answerPrompt(...)` from any thread.
- `Listener.onState` calls come one at a time, from one goroutine, but possibly on different OS threads. The
  listener may call anything on the node, `close()` too.
- Calls into Go from Kotlin may come from any thread. `Session` methods are thread-safe; `connect()` returns at once,
  `disconnect()` works in the background (the end comes as `StateDisconnected`). `Node` methods block for up to 10
  to 20 seconds (`dial` up to its timeout): use a background dispatcher.
