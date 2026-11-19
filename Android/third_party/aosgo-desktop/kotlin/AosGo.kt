// The JNA binding of aosgo, the Go library of aOS's desktop companion (Android/third_party/aosgo-desktop; the C API
// is go/aosgo.h there, which this file follows). One library holds Open Screen Sharing's libsharing (GPL-3.0) and
// aOS's Tailscale node; the API mirrors the Android app's gomobile classes (dev.marquart.aos.libsharing and
// dev.marquart.aos.tailnetkit), so code ported from the Android app reads almost the same.
//
// Part of aOS's desktop wrapper of Open Screen Sharing; GPL-3.0 like it (Open Screen Sharing by nekohasekai;
// iOS/ThirdParty/OpenScreenSharing/LICENSE and COPYING in aOS).
//
// Needs JNA (net.java.dev.jna:jna) and kotlinx-serialization-json (only its JSON tree, no compiler plugin). The
// library is found as "aosgo" on jna.library.path (aosgo.dll, libaosgo.so, libaosgo.dylib), or at the absolute path in
// the system property aosgo.library.

package dev.marquart.aos.desktop.native

import com.sun.jna.Callback
import com.sun.jna.CallbackThreadInitializer
import com.sun.jna.Library
import com.sun.jna.Memory
import com.sun.jna.Native
import com.sun.jna.Pointer
import com.sun.jna.ptr.PointerByReference
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.util.concurrent.ConcurrentHashMap

/** A call into aosgo failed; the message is the library's. */
class AosGoException(message: String) : Exception(message)

// MARK: The C functions

/** aosgo.h as JNA sees it. Use the classes below; this is the raw mapping. */
@Suppress("FunctionName")
interface AosGoLibrary : Library {
    fun aosgo_free(pointer: Pointer?)
    fun aosgo_version(): Pointer?
    fun aosgo_set_log_handler(fn: LogCallback?, minimumLevel: Int)

    fun aosgo_session_new(optionsJSON: String, callback: SessionCallback, error: PointerByReference?): Long
    fun aosgo_session_connect(session: Long, error: PointerByReference?): Int
    fun aosgo_session_disconnect(session: Long)
    fun aosgo_session_abort(session: Long)
    fun aosgo_session_free(session: Long)
    fun aosgo_session_attach_framebuffer(session: Long, address: Long, width: Int, height: Int, bytesPerRow: Int, error: PointerByReference?): Int
    fun aosgo_session_send_pointer(session: Long, x: Int, y: Int, buttons: Int, clickCount: Int, error: PointerByReference?): Int
    fun aosgo_session_send_scroll(session: Long, x: Int, y: Int, deltaX: Double, deltaY: Double, error: PointerByReference?): Int
    fun aosgo_session_send_scroll_phase(session: Long, x: Int, y: Int, deltaX: Double, deltaY: Double, phase: Int, error: PointerByReference?): Int
    fun aosgo_session_start_scroll_momentum(session: Long, x: Int, y: Int, velocityX: Double, velocityY: Double, error: PointerByReference?): Int
    fun aosgo_session_stop_scroll_momentum(session: Long)
    fun aosgo_session_send_magnify(session: Long, x: Int, y: Int, magnification: Double, phase: Int, error: PointerByReference?): Int
    fun aosgo_session_send_rotate(session: Long, x: Int, y: Int, degrees: Double, phase: Int, error: PointerByReference?): Int
    fun aosgo_session_send_key(session: Long, keysym: Int, down: Int, error: PointerByReference?): Int
    fun aosgo_session_send_key_code(session: Long, keyCode: Int, keyboardType: Int, keysym: Int, down: Int, error: PointerByReference?): Int
    fun aosgo_session_send_text(session: Long, text: String, error: PointerByReference?): Int
    fun aosgo_session_paste_text(session: Long, text: String, error: PointerByReference?): Int
    fun aosgo_session_send_system_command(session: Long, command: Int, error: PointerByReference?): Int
    fun aosgo_session_set_assist_cursor(session: Long, x: Int, y: Int, pressed: Int, error: PointerByReference?): Int
    fun aosgo_session_hide_assist_cursor(session: Long, error: PointerByReference?): Int
    fun aosgo_session_set_clipboard(session: Long, clipboardJSON: String, data: ByteArray?, length: Long, error: PointerByReference?): Int
    fun aosgo_session_paste_clipboard(session: Long, clipboardJSON: String, data: ByteArray?, length: Long, error: PointerByReference?): Int
    fun aosgo_session_set_clipboard_text(session: Long, text: String, error: PointerByReference?): Int
    fun aosgo_session_request_clipboard(session: Long, error: PointerByReference?): Int
    fun aosgo_session_set_shared_clipboard(session: Long, enabled: Int, error: PointerByReference?): Int
    fun aosgo_session_set_virtual_display(session: Long, width: Int, height: Int, density: Double, maximumWidth: Int, maximumHeight: Int, error: PointerByReference?): Int
    fun aosgo_session_display_width_multiple(session: Long): Int
    fun aosgo_session_select_display(session: Long, displayID: Long, error: PointerByReference?): Int
    fun aosgo_session_set_quality(session: Long, quality: Int, error: PointerByReference?): Int
    fun aosgo_session_set_mode(session: Long, mode: Int, error: PointerByReference?): Int
    fun aosgo_session_set_update_rate(session: Long, rate: Int, error: PointerByReference?): Int
    fun aosgo_session_set_visible(session: Long, visible: Int, error: PointerByReference?): Int
    fun aosgo_session_select_keyboard_source(session: Long, sourceID: String, error: PointerByReference?): Int
    fun aosgo_session_request_refresh(session: Long, error: PointerByReference?): Int
    fun aosgo_session_answer_prompt(session: Long, promptID: Long, answer: Int, error: PointerByReference?): Int
    fun aosgo_session_statistics(session: Long, error: PointerByReference?): Pointer?
    fun aosgo_session_start_high_performance(session: Long, optionsJSON: String, error: PointerByReference?): Int
    fun aosgo_session_restart_high_performance(session: Long, optionsJSON: String, error: PointerByReference?): Int
    fun aosgo_session_set_hdr(session: Long, enabled: Int, error: PointerByReference?): Int
    fun aosgo_session_request_keyframe(session: Long, error: PointerByReference?): Int
    fun aosgo_session_upload_file(session: Long, localPath: String, remoteFolder: String, error: PointerByReference?): Long
    fun aosgo_session_download_file(session: Long, remotePath: String, localFolder: String, error: PointerByReference?): Long
    fun aosgo_session_download_files(session: Long, remotePaths: String, localFolder: String, error: PointerByReference?): Int
    fun aosgo_session_cancel_transfer(session: Long, transferID: Long, error: PointerByReference?): Int
    fun aosgo_session_start_drop(session: Long, names: String, error: PointerByReference?): Long
    fun aosgo_session_cancel_drag(session: Long, dragID: Long, error: PointerByReference?): Int
    fun aosgo_session_cancel_remote_drag(session: Long, error: PointerByReference?): Int
    fun aosgo_check_login(optionsJSON: String, error: PointerByReference?): Pointer?
    fun aosgo_probe_server(host: String, port: Int, error: PointerByReference?): Pointer?

    fun aosgo_tailnet_built_for_aos(): Int
    fun aosgo_tailnet_is_sign_in_page(url: String): Int
    fun aosgo_tailnet_new(dir: String, hostname: String, controlURL: String, log: TailnetLogCallback?, error: PointerByReference?): Long
    fun aosgo_tailnet_start(node: Long, listener: TailnetStateCallback?, error: PointerByReference?): Int
    fun aosgo_tailnet_state(node: Long, error: PointerByReference?): Pointer?
    fun aosgo_tailnet_status_json(node: Long, error: PointerByReference?): Pointer?
    fun aosgo_tailnet_login(node: Long, error: PointerByReference?): Int
    fun aosgo_tailnet_logout(node: Long, error: PointerByReference?): Int
    fun aosgo_tailnet_dial(node: Long, host: String, port: Int, timeoutMillis: Int, clientPort: Int, error: PointerByReference?): Int
    fun aosgo_tailnet_close(node: Long)
}

interface LogCallback : Callback {
    fun invoke(level: Int, message: Pointer?)
}

interface SessionCallback : Callback {
    fun invoke(session: Long, kind: Int, a: Long, b: Long, c: Long, d: Long, e: Long, text: Pointer?, data: Pointer?, length: Long)
}

interface TailnetLogCallback : Callback {
    fun invoke(node: Long, line: Pointer?)
}

interface TailnetStateCallback : Callback {
    fun invoke(node: Long, stateJSON: Pointer?)
}

// MARK: The library

object AosGo {
    /** The loaded library (loads it on first use). */
    val library: AosGoLibrary by lazy {
        val name = System.getProperty("aosgo.library")?.takeIf { it.isNotEmpty() } ?: "aosgo"
        Native.load(name, AosGoLibrary::class.java, mapOf(Library.OPTION_STRING_ENCODING to "UTF-8"))
    }

    internal val json = Json { ignoreUnknownKeys = true }

    /** Callbacks run on Go threads: attach each one once and keep it attached (daemon), instead of per call. */
    internal fun <T : Callback> keepAttached(callback: T, name: String): T {
        Native.setCallbackThreadInitializer(callback, CallbackThreadInitializer(true, false, name))
        return callback
    }

    /** What the library was built from (the corresponding source for GPL-3.0). */
    fun version(): String = takeString(library.aosgo_version()) ?: ""

    @Volatile private var logHandler: ((Int, String) -> Unit)? = null
    private val logCallback = keepAttached(object : LogCallback {
        override fun invoke(level: Int, message: Pointer?) {
            val handler = logHandler ?: return
            runCatching { handler(level, message?.getString(0, "UTF-8") ?: "") }
        }
    }, "aosgo-log")

    /**
     * libsharing's log of sessions created from now on (Libsharing.setLogHandler): level -4 debug, 0 info, 4 warn,
     * 8 error. null stops it. Host names may be in it.
     */
    fun setLogHandler(minimumLevel: Int, handler: ((level: Int, message: String) -> Unit)?) {
        logHandler = handler
        library.aosgo_set_log_handler(if (handler == null) null else logCallback, minimumLevel)
    }

    /** Logs in once and disconnects (ProbeRequest.checkLogin). Blocks (network): not on the UI thread. */
    fun checkLogin(options: SessionOptions): LoginCheck {
        val o = jsonCall { library.aosgo_check_login(options.toJson(), it) }
        return LoginCheck(o.bool("supportsHighPerformance"), o.str("fingerprint"), o.str("security"), o.int("errorCode"), o.str("errorMessage"))
    }

    /** What a server offers (ProbeRequest.probeServer). Blocks (network). */
    fun probeServer(host: String, port: Int): ServerProbe {
        val o = jsonCall { library.aosgo_probe_server(host, port, it) }
        return ServerProbe(
            o.int("protocol"), o.int("port"), o.str("fingerprint"), o.bool("supportsAccount"), o.bool("supportsRequestControl"),
            o.bool("supportsRequestObserve"), o.bool("supportsVNCPassword"), o.bool("supportsNoPassword"), o.bool("grantsRequests"),
            o.int("errorCode"), o.str("errorMessage"),
        )
    }

    // Helpers for the calls

    /** A string the library returned, freed. */
    internal fun takeString(pointer: Pointer?): String? {
        pointer ?: return null
        try {
            return pointer.getString(0, "UTF-8")
        } finally {
            library.aosgo_free(pointer)
        }
    }

    internal fun check(result: Long, error: PointerByReference): Long {
        if (result < 0) throw AosGoException(takeString(error.value) ?: "aosgo: failed")
        return result
    }

    internal inline fun status(call: (PointerByReference) -> Int) {
        val error = PointerByReference()
        check(call(error).toLong(), error)
    }

    internal inline fun handle(call: (PointerByReference) -> Long): Long {
        val error = PointerByReference()
        return check(call(error), error)
    }

    internal inline fun stringCall(call: (PointerByReference) -> Pointer?): String {
        val error = PointerByReference()
        return takeString(call(error)) ?: throw AosGoException(takeString(error.value) ?: "aosgo: failed")
    }

    internal inline fun jsonCall(call: (PointerByReference) -> Pointer?): JsonObject = json.parseToJsonElement(stringCall(call)).jsonObject
}

// JSON helpers (missing keys read as 0, false, "").
internal fun JsonObject.long(key: String): Long = (this[key] as? JsonPrimitive)?.longOrNull ?: 0L
internal fun JsonObject.int(key: String): Int = long(key).toInt()
internal fun JsonObject.double(key: String): Double = (this[key] as? JsonPrimitive)?.doubleOrNull ?: 0.0
internal fun JsonObject.bool(key: String): Boolean = (this[key] as? JsonPrimitive)?.booleanOrNull ?: false
internal fun JsonObject.str(key: String): String = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: ""
internal fun JsonObject.array(key: String): List<JsonObject> = (this[key] as? JsonArray)?.map { it.jsonObject } ?: emptyList()
private fun Boolean.int() = if (this) 1 else 0
private fun Long.bool() = this != 0L

// MARK: libsharing: constants (Libsharing.* on Android)

@Suppress("unused", "ConstPropertyName")
object Libsharing {
    const val ProtocolRFB = 0; const val ProtocolRDP = 1
    const val PlatformUnknown = 0; const val PlatformMac = 1; const val PlatformPC = 2
    const val LoginAccount = 0; const val LoginRequestControl = 1; const val LoginRequestObserve = 2
    const val LoginVNCPassword = 3; const val LoginNone = 4
    const val QualityAdaptive = 0; const val QualityFull = 1; const val QualityHigh = 2; const val QualityMedium = 3; const val QualityLow = 4
    const val ModeObserve = 0; const val ModeControl = 1; const val ModeExclusiveControl = 2
    const val DialectApple = 1; const val DialectStandard = 2; const val DialectRDP = 3
    const val KeyboardANSI = 40; const val KeyboardISO = 41; const val KeyboardJIS = 42
    const val StateConnecting = 1; const val StateAuthenticating = 2; const val StateWaitingForApproval = 3
    const val StateChoosingSession = 4; const val StateConnected = 5; const val StateDisconnected = 6
    const val ErrorNone = 0; const val ErrorAuthentication = 1; const val ErrorPermissionDenied = 2; const val ErrorNetwork = 3
    const val ErrorProtocol = 4; const val ErrorCancelled = 5; const val ErrorUnsupportedServer = 6; const val ErrorUnverifiedServer = 7
    const val ErrorSessionEnded = 8; const val ErrorHostNotFound = 9; const val ErrorOwnScreen = 10; const val ErrorCertificateChanged = 11
    const val ButtonLeft = 1; const val ButtonMiddle = 2; const val ButtonRight = 4
    const val ClipboardProblemNotRestored = 2
    const val SessionChoiceCancel = -1; const val SessionChoiceShareConsole = 0; const val SessionChoiceOwnSession = 2
    const val StatusControlAllowed = 9; const val StatusObserveOnly = 10; const val StatusPointerHidden = 11; const val StatusPointerShown = 12
    const val AllDisplays = 0L
    const val GesturePhaseBegan = 1; const val GesturePhaseChanged = 2; const val GesturePhaseEnded = 4
    const val GesturePhaseCancelled = 8; const val GesturePhaseMayBegin = 0x80
    const val SystemCommandMissionControl = 1; const val SystemCommandAppWindows = 2
    const val SystemCommandShowDesktop = 3; const val SystemCommandLaunchpad = 4
    const val CodecHEVC = 1; const val CodecH264 = 2
    const val DecoderCodecHEVC = 1 shl 0; const val DecoderCodecH264 = 1 shl 1
    const val MediaErrorNone = 0; const val MediaErrorBusy = 1; const val MediaErrorRefused = 2
    const val MediaErrorSilent = 3; const val MediaErrorNetwork = 4
    const val VideoModeCoreDevice = 5; const val VideoModeRemoteDesktop = 7
    const val FileErrorNone = 0; const val FileErrorCancelled = 1; const val FileErrorNotAllowed = 2; const val FileErrorNotFound = 3
    const val FileErrorNotWritable = 4; const val FileErrorDiskFull = 5; const val FileErrorPermission = 6; const val FileErrorLocal = 7
    const val FileErrorConnection = 8; const val FileErrorFailed = 9; const val FileErrorObserveOnly = 10; const val FileErrorUnsupported = 11

    /** The clipboard type of plain text. */
    const val UTF8PlainText = "public.utf8-plain-text"
}

// MARK: libsharing: values

/** Libsharing.newSessionOptions() with its defaults; aOS's Android app sets protocol, platform Mac, keepAlive, ... */
data class SessionOptions(
    val host: String,
    val port: Int = 5900,
    val username: String = "",
    val password: String = "",
    val protocol: Int = Libsharing.ProtocolRFB,
    val trustedFingerprint: String = "",
    val requireTrustedKey: Boolean = false,
    val allowUnverifiedLogin: Boolean = false,
    val keyboardLayout: Int = 0,
    val audio: Boolean = false,
    val microphone: Boolean = false,
    val loginType: Int = Libsharing.LoginAccount,
    val quality: Int = Libsharing.QualityAdaptive,
    val mode: Int = Libsharing.ModeControl,
    val sharedClipboard: Boolean = true,
    val clientName: String = "",
    val platform: Int = Libsharing.PlatformUnknown,
    val decoderMaxPixelRate: Long = 0,
    val maximumFrameRate: Int = 0,
    val updateRate: Int = 0,
    val keepAlive: Boolean = false,
    val disableUDP: Boolean = false,
    val cacheDirectory: String = "",
) {
    fun toJson(): String = buildJsonObject {
        put("host", host); put("port", port); put("username", username); put("password", password); put("protocol", protocol)
        put("trustedFingerprint", trustedFingerprint); put("requireTrustedKey", requireTrustedKey)
        put("allowUnverifiedLogin", allowUnverifiedLogin); put("keyboardLayout", keyboardLayout); put("audio", audio)
        put("microphone", microphone); put("loginType", loginType); put("quality", quality); put("mode", mode)
        put("sharedClipboard", sharedClipboard); put("clientName", clientName); put("platform", platform)
        put("decoderMaxPixelRate", decoderMaxPixelRate); put("maximumFrameRate", maximumFrameRate); put("updateRate", updateRate)
        put("keepAlive", keepAlive); put("disableUDP", disableUDP); put("cacheDirectory", cacheDirectory)
    }.toString()

    override fun toString() = "SessionOptions(host=$host, port=$port, username=$username, loginType=$loginType)" // no password
}

/** Libsharing.newHighPerformanceOptions() with its defaults. pixelFormats bits: 0, 1 4:2:0 8 bit; 3, 4 4:4:4; 5 HDR. */
data class HighPerformanceOptions(
    val supportedCodecs: Int = Libsharing.DecoderCodecHEVC,
    val pixelFormats: Int = 0,
    val audio: Boolean = true,
    val bands: Int = 1,
    val videoMode: Int = 0,
    val immediatePlayout: Boolean = false,
) {
    fun toJson(): String = buildJsonObject {
        put("supportedCodecs", supportedCodecs); put("pixelFormats", pixelFormats); put("audio", audio); put("bands", bands)
        put("videoMode", videoMode); put("immediatePlayout", immediatePlayout)
    }.toString()
}

data class LoginCheck(val supportsHighPerformance: Boolean, val fingerprint: String, val security: String, val errorCode: Int, val errorMessage: String)

data class ServerProbe(
    val protocol: Int, val port: Int, val fingerprint: String, val supportsAccount: Boolean, val supportsRequestControl: Boolean,
    val supportsRequestObserve: Boolean, val supportsVNCPassword: Boolean, val supportsNoPassword: Boolean, val grantsRequests: Boolean,
    val errorCode: Int, val errorMessage: String,
)

/** Android's ServerInfo; the JSON has every getter, `raw` keeps it for ones added later. */
data class ServerInfo(
    val width: Int, val height: Int, val dialect: Int, val platform: Int, val cursorPixelsPerPoint: Double, val observeOnly: Boolean,
    val supportsDisplaySelection: Boolean, val supportsVirtualDisplay: Boolean, val supportsHighPerformance: Boolean,
    val supportsClipboard: Boolean, val supportsClipboardRequest: Boolean, val supportsKeyboardSource: Boolean,
    val supportsQuality: Boolean, val supportsObserve: Boolean, val supportsAudio: Boolean, val supportsUnicodeText: Boolean,
    val supportsKeyCodes: Boolean, val supportsFileTransfer: Boolean, val supportsDragToRemote: Boolean,
    val supportsDragFromRemote: Boolean, val supportsGestures: Boolean, val supportsTouch: Boolean, val supportsAssistCursor: Boolean,
    val supportsMissionControl: Boolean, val supportsAppWindows: Boolean, val supportsShowDesktop: Boolean, val supportsLaunchpad: Boolean,
    val raw: JsonObject,
) {
    companion object {
        fun from(o: JsonObject) = ServerInfo(
            o.int("width"), o.int("height"), o.int("dialect"), o.int("platform"), o.double("cursorPixelsPerPoint"), o.bool("observeOnly"),
            o.bool("supportsDisplaySelection"), o.bool("supportsVirtualDisplay"), o.bool("supportsHighPerformance"),
            o.bool("supportsClipboard"), o.bool("supportsClipboardRequest"), o.bool("supportsKeyboardSource"),
            o.bool("supportsQuality"), o.bool("supportsObserve"), o.bool("supportsAudio"), o.bool("supportsUnicodeText"),
            o.bool("supportsKeyCodes"), o.bool("supportsFileTransfer"), o.bool("supportsDragToRemote"),
            o.bool("supportsDragFromRemote"), o.bool("supportsGestures"), o.bool("supportsTouch"), o.bool("supportsAssistCursor"),
            o.bool("supportsMissionControl"), o.bool("supportsAppWindows"), o.bool("supportsShowDesktop"), o.bool("supportsLaunchpad"),
            o,
        )
    }
}

data class FramebufferUpdate(val x: Int, val y: Int, val width: Int, val height: Int, val holdNanoseconds: Long)

/** pixels: width*height*4 bytes, B, G, R, A in memory (OSS's CursorTheme/StandardCursor show how the iPhone draws it). */
class CursorImage(val width: Int, val height: Int, val hotspotX: Int, val hotspotY: Int, val pixels: ByteArray, val invert: ByteArray)

data class Display(val displayID: Long, val logicalWidth: Int, val logicalHeight: Int, val isMain: Boolean, val isVirtual: Boolean)

data class DisplayList(val current: Long, val framebufferWidth: Int, val desktopWidth: Int, val displays: List<Display>)

class ClipboardFlavor(val type: String, val data: ByteArray, val promise: Boolean = false)

class ClipboardItem(val flavors: List<ClipboardFlavor>)

class Clipboard(val items: List<ClipboardItem>) {
    /** The first plain text flavor that isn't a promise, or null. */
    fun text(): String? = items.firstNotNullOfOrNull { item ->
        item.flavors.firstOrNull { !it.promise && it.type == Libsharing.UTF8PlainText }?.let { String(it.data, Charsets.UTF_8) }
    }

    internal fun layout(): Pair<String, ByteArray> {
        val data = java.io.ByteArrayOutputStream()
        val text = buildJsonObject {
            put("items", buildJsonArray {
                for (item in items) add(buildJsonObject {
                    put("flavors", buildJsonArray {
                        for (flavor in item.flavors) {
                            add(buildJsonObject {
                                put("type", flavor.type); put("promise", flavor.promise); put("offset", data.size()); put("length", flavor.data.size)
                            })
                            data.write(flavor.data)
                        }
                    })
                })
            })
        }.toString()
        return text to data.toByteArray()
    }

    companion object {
        fun text(text: String) = Clipboard(listOf(ClipboardItem(listOf(ClipboardFlavor(Libsharing.UTF8PlainText, text.toByteArray(Charsets.UTF_8))))))

        internal fun from(o: JsonObject, data: ByteArray) = Clipboard(o.array("items").map { item ->
            ClipboardItem(item.array("flavors").map { f ->
                val offset = f.int("offset"); val length = f.int("length")
                ClipboardFlavor(f.str("type"), data.copyOfRange(offset, offset + length), f.bool("promise"))
            })
        })
    }
}

data class Prompt(val promptID: Long, val consoleUser: String, val allowsShareConsole: Boolean, val allowsOwnSession: Boolean)

/**
 * The video stream's format. parameterSets: raw NAL units (no start code, no length), in stream order (HEVC: VPS,
 * SPS, PPS; H.264: SPS, PPS). height: the whole picture (all bands). chromaFormat 1 = 4:2:0, 3 = 4:4:4.
 */
class VideoFormat(val codec: Int, val bands: Int, val height: Int, val chromaFormat: Int, val hdr: Boolean, val parameterSets: List<ByteArray>)

/**
 * One access unit: data = length-prefixed NAL units (4 byte big-endian lengths), without parameter sets. For Annex B
 * decoders replace each length with 00 00 00 01 in place (third_party/README.md, "High performance").
 */
class VideoAccessUnit(
    val data: ByteArray, val timestamp: Long, val clockRate: Int, val sync: Boolean, val band: Int, val bands: Int, val frameID: Long,
    val frameEnd: Boolean, val changedBands: Int, val discontinuity: Boolean, val turns: Int, val holdNanoseconds: Long,
    val composed: Boolean, val composeNanoseconds: Long,
)

class AudioFormat(val formatID: Long, val sampleRate: Int, val channels: Int, val framesPerPacket: Int, val magicCookie: ByteArray)

class AudioPacket(val data: ByteArray, val timestamp: Long, val lost: Int)

data class RemoteDragItem(val path: String, val isFolder: Boolean)

class RemoteDrag(val items: List<RemoteDragItem>, val image: ByteArray?)

data class Statistics(
    val roundTripMilliseconds: Double, val receivedBytes: Long, val encoding: String, val highPerformance: Boolean, val udp: Boolean,
    val packets: Long, val packetsExpected: Long, val videoLosses: Long,
)

/**
 * Memory libsharing draws the remote screen into: width*height pixels, 4 bytes each in memory order B, G, R, X (X
 * undefined: draw opaque; Skia's BGRA_8888 with an opaque alpha type), rows bytesPerRow apart, top row first. Zero at
 * first. Native memory (JNA Memory), freed when this object is garbage collected or closed.
 *
 * Don't close it while libsharing may write into it: AosGoSession keeps a reference to what it attached until that
 * is safe (see AosGoSession.attachFramebuffer); keep your own as long as you read it.
 */
class Framebuffer(val width: Int, val height: Int) : AutoCloseable {
    init {
        require(width in 1..16384 && height in 1..16384) { "framebuffer size ${width}x$height" }
    }

    val bytesPerRow: Int = width * 4
    val memory: Memory = Memory(bytesPerRow.toLong() * height).also { it.clear() }
    val address: Long get() = Pointer.nativeValue(memory)

    /** Copies a rectangle out (e.g. after onFramebufferUpdate), rows packed (width*4 bytes each). */
    fun read(x: Int, y: Int, w: Int, h: Int): ByteArray {
        val out = ByteArray(w * h * 4)
        for (row in 0 until h) memory.read((y + row).toLong() * bytesPerRow + x * 4L, out, row * w * 4, w * 4)
        return out
    }

    override fun close() = memory.close()
}

// MARK: libsharing: the session

/**
 * Android's SessionHandler: every method is called on a Go thread (never the UI thread), one event at a time per
 * session in order (video and audio from the media stream's threads). Return quickly. Exceptions are caught and
 * printed (they never reach Go).
 */
interface SessionHandler {
    fun onStateChanged(state: Int, errorCode: Int, message: String) {}
    fun onServerInfo(info: ServerInfo) {}
    fun onServerCertificate(fingerprint: String) {}

    /**
     * Before the first picture and on every size change. Attach a framebuffer of exactly this size before returning
     * (`session.attachFramebuffer(Framebuffer(width, height))`), or the session fails.
     */
    fun onFramebufferResize(session: AosGoSession, width: Int, height: Int)
    fun onFramebufferUpdate(update: FramebufferUpdate) {}

    /** null: no cursor image. */
    fun onCursorImage(cursor: CursorImage?) {}
    fun onCursorPosition(x: Int, y: Int) {}
    fun onDisplays(displays: DisplayList) {}
    fun onClipboard(clipboard: Clipboard) {}
    fun onClipboardProblem(kind: Int, message: String) {}
    fun onBell() {}
    fun onKeyboardSource(sourceID: String, secureInput: Boolean) {}
    fun onStatus(status: Int) {}

    /** The session waits for session.answerPrompt(prompt.promptID, ...) (from any thread, later too). */
    fun onPrompt(prompt: Prompt) {}
    fun onVideoFormat(format: VideoFormat) {}
    fun onVideoAccessUnit(unit: VideoAccessUnit) {}
    fun onAudioFormat(format: AudioFormat) {}
    fun onAudioPacket(packet: AudioPacket) {}
    fun onMicrophone(format: AudioFormat) {}
    fun onMediaStopped(errorCode: Int, message: String) {}
    fun onFileTransferProgress(transferID: Long, transferred: Long, total: Long) {}
    fun onFileTransferFinished(transferID: Long, name: String, errorCode: Int, message: String) {}
    fun onDropDestination(dragID: Long, path: String) {}

    /** null: the drag ended. */
    fun onRemoteDrag(drag: RemoteDrag?) {}
    fun onDeviceInfo(model: String, deviceColor: String, enclosureColor: String) {}
}

/**
 * libsharing's Session (Libsharing.newSession). Methods may be called from any thread; failures throw
 * AosGoException. connect() returns at once (progress comes as onStateChanged); disconnect() ends it in the
 * background. close() releases it (aborting it if it still runs; onStateChanged(StateDisconnected) still comes).
 */
class AosGoSession(options: SessionOptions, private val handler: SessionHandler) : AutoCloseable {
    private val lib = AosGo.library
    val handle: Long

    // Framebuffers libsharing may still write into (the attached one, and replaced ones until that's safe).
    private val retainedLock = Any()
    private var retained: List<Framebuffer> = emptyList()

    // The handle stays in the dispatcher's map until it is freed and its last event (DISCONNECTED) came.
    private val lifecycle = Any()
    private var live = false // connected, DISCONNECTED not yet seen
    private var closed = false

    init {
        handle = AosGo.handle { lib.aosgo_session_new(options.toJson(), Dispatcher.callback, it) }
        Dispatcher.sessions[handle] = this
    }

    fun connect() = synchronized(lifecycle) {
        AosGo.status { lib.aosgo_session_connect(handle, it) }
        live = true
    }

    fun disconnect() = lib.aosgo_session_disconnect(handle)
    fun abort() = lib.aosgo_session_abort(handle)

    /** Releases the session (idempotent). A running one is aborted; its onStateChanged(StateDisconnected) still comes. */
    override fun close() {
        synchronized(lifecycle) {
            if (closed) return
            closed = true
            lib.aosgo_session_free(handle)
            if (!live) Dispatcher.sessions.remove(handle)
        }
    }

    /**
     * Hands libsharing the framebuffer (inside onFramebufferResize with that size; outside, on a connected session,
     * it replaces the current one). The session keeps a reference to it (and to replaced ones) until libsharing can
     * no longer write into them: the next resize returned, or the session disconnected.
     */
    fun attachFramebuffer(framebuffer: Framebuffer) {
        attachFramebuffer(framebuffer.address, framebuffer.width, framebuffer.height, framebuffer.bytesPerRow)
        synchronized(retainedLock) { retained = retained + framebuffer }
    }

    /**
     * Any memory as the framebuffer (e.g. a Skia Pixmap's address): yours to keep valid until another one was
     * attached and that resize callback returned, or until onStateChanged(StateDisconnected).
     */
    fun attachFramebuffer(address: Long, width: Int, height: Int, bytesPerRow: Int) =
        AosGo.status { lib.aosgo_session_attach_framebuffer(handle, address, width, height, bytesPerRow, it) }

    fun sendPointer(x: Int, y: Int, buttons: Int, clickCount: Int) = AosGo.status { lib.aosgo_session_send_pointer(handle, x, y, buttons, clickCount, it) }
    fun sendScroll(x: Int, y: Int, dx: Double, dy: Double) = AosGo.status { lib.aosgo_session_send_scroll(handle, x, y, dx, dy, it) }
    fun sendScrollPhase(x: Int, y: Int, dx: Double, dy: Double, phase: Int) = AosGo.status { lib.aosgo_session_send_scroll_phase(handle, x, y, dx, dy, phase, it) }
    fun startScrollMomentum(x: Int, y: Int, vx: Double, vy: Double) = AosGo.status { lib.aosgo_session_start_scroll_momentum(handle, x, y, vx, vy, it) }
    fun stopScrollMomentum() = lib.aosgo_session_stop_scroll_momentum(handle)
    fun sendMagnify(x: Int, y: Int, magnification: Double, phase: Int) = AosGo.status { lib.aosgo_session_send_magnify(handle, x, y, magnification, phase, it) }
    fun sendRotate(x: Int, y: Int, degrees: Double, phase: Int) = AosGo.status { lib.aosgo_session_send_rotate(handle, x, y, degrees, phase, it) }
    fun sendKey(keysym: Int, down: Boolean) = AosGo.status { lib.aosgo_session_send_key(handle, keysym, down.int(), it) }
    fun sendKeyCode(keyCode: Int, keyboardType: Int, keysym: Int, down: Boolean) =
        AosGo.status { lib.aosgo_session_send_key_code(handle, keyCode, keyboardType, keysym, down.int(), it) }
    fun sendText(text: String) = AosGo.status { lib.aosgo_session_send_text(handle, text, it) }
    fun pasteText(text: String) = AosGo.status { lib.aosgo_session_paste_text(handle, text, it) }
    fun sendSystemCommand(command: Int) = AosGo.status { lib.aosgo_session_send_system_command(handle, command, it) }
    fun setAssistCursor(x: Int, y: Int, pressed: Boolean) = AosGo.status { lib.aosgo_session_set_assist_cursor(handle, x, y, pressed.int(), it) }
    fun hideAssistCursor() = AosGo.status { lib.aosgo_session_hide_assist_cursor(handle, it) }

    fun setClipboard(clipboard: Clipboard) {
        val (text, data) = clipboard.layout()
        AosGo.status { lib.aosgo_session_set_clipboard(handle, text, data.takeIf { it.isNotEmpty() }, data.size.toLong(), it) }
    }

    fun pasteClipboard(clipboard: Clipboard) {
        val (text, data) = clipboard.layout()
        AosGo.status { lib.aosgo_session_paste_clipboard(handle, text, data.takeIf { it.isNotEmpty() }, data.size.toLong(), it) }
    }

    fun setClipboardText(text: String) = AosGo.status { lib.aosgo_session_set_clipboard_text(handle, text, it) }
    fun requestClipboard() = AosGo.status { lib.aosgo_session_request_clipboard(handle, it) }
    fun setSharedClipboard(enabled: Boolean) = AosGo.status { lib.aosgo_session_set_shared_clipboard(handle, enabled.int(), it) }

    fun setVirtualDisplay(width: Int, height: Int, density: Double, maximumWidth: Int, maximumHeight: Int) =
        AosGo.status { lib.aosgo_session_set_virtual_display(handle, width, height, density, maximumWidth, maximumHeight, it) }
    fun displayWidthMultiple(): Int = lib.aosgo_session_display_width_multiple(handle)
    fun selectDisplay(displayID: Long) = AosGo.status { lib.aosgo_session_select_display(handle, displayID, it) }
    fun setQuality(quality: Int) = AosGo.status { lib.aosgo_session_set_quality(handle, quality, it) }
    fun setMode(mode: Int) = AosGo.status { lib.aosgo_session_set_mode(handle, mode, it) }
    fun setUpdateRate(rate: Int) = AosGo.status { lib.aosgo_session_set_update_rate(handle, rate, it) }
    fun setVisible(visible: Boolean) = AosGo.status { lib.aosgo_session_set_visible(handle, visible.int(), it) }
    fun selectKeyboardSource(sourceID: String) = AosGo.status { lib.aosgo_session_select_keyboard_source(handle, sourceID, it) }
    fun requestRefresh() = AosGo.status { lib.aosgo_session_request_refresh(handle, it) }
    fun answerPrompt(promptID: Long, answer: Int) = AosGo.status { lib.aosgo_session_answer_prompt(handle, promptID, answer, it) }

    fun statistics(): Statistics {
        val o = AosGo.jsonCall { lib.aosgo_session_statistics(handle, it) }
        return Statistics(
            o.double("roundTripMilliseconds"), o.long("receivedBytes"), o.str("encoding"), o.bool("highPerformance"), o.bool("udp"),
            o.long("packets"), o.long("packetsExpected"), o.long("videoLosses"),
        )
    }

    fun startHighPerformance(options: HighPerformanceOptions) = AosGo.status { lib.aosgo_session_start_high_performance(handle, options.toJson(), it) }
    fun restartHighPerformance(options: HighPerformanceOptions) = AosGo.status { lib.aosgo_session_restart_high_performance(handle, options.toJson(), it) }
    fun setHDR(enabled: Boolean) = AosGo.status { lib.aosgo_session_set_hdr(handle, enabled.int(), it) }
    fun requestKeyframe() = AosGo.status { lib.aosgo_session_request_keyframe(handle, it) }

    /** Returns the transfer id; progress and the end come as onFileTransfer... */
    fun uploadFile(localPath: String, remoteFolder: String = ""): Long = AosGo.handle { lib.aosgo_session_upload_file(handle, localPath, remoteFolder, it) }
    fun downloadFile(remotePath: String, localFolder: String): Long = AosGo.handle { lib.aosgo_session_download_file(handle, remotePath, localFolder, it) }

    /** Blocks until all are there. */
    fun downloadFiles(remotePaths: List<String>, localFolder: String) =
        AosGo.status { lib.aosgo_session_download_files(handle, remotePaths.joinToString("\n"), localFolder, it) }
    fun cancelTransfer(transferID: Long) = AosGo.status { lib.aosgo_session_cancel_transfer(handle, transferID, it) }
    fun startDrop(names: List<String>): Long = AosGo.handle { lib.aosgo_session_start_drop(handle, names.joinToString("\n"), it) }
    fun cancelDrag(dragID: Long) = AosGo.status { lib.aosgo_session_cancel_drag(handle, dragID, it) }
    fun cancelRemoteDrag() = AosGo.status { lib.aosgo_session_cancel_remote_drag(handle, it) }

    // Events (Dispatcher)

    internal fun event(kind: Int, a: Long, b: Long, c: Long, d: Long, e: Long, text: String?, data: ByteArray?) {
        when (kind) {
            1 -> {
                try {
                    handler.onStateChanged(a.toInt(), b.toInt(), text ?: "")
                } finally {
                    if (a.toInt() == Libsharing.StateDisconnected) {
                        synchronized(retainedLock) { retained = emptyList() }
                        synchronized(lifecycle) {
                            live = false
                            if (closed) Dispatcher.sessions.remove(handle)
                        }
                    }
                }
            }
            2 -> handler.onServerInfo(ServerInfo.from(obj(text)))
            3 -> handler.onServerCertificate(text ?: "")
            4 -> {
                try {
                    handler.onFramebufferResize(this, a.toInt(), b.toInt())
                } finally {
                    // The resize returned: libsharing writes only into the framebuffer attached last.
                    synchronized(retainedLock) { retained = retained.takeLast(1) }
                }
            }
            5 -> handler.onFramebufferUpdate(FramebufferUpdate(a.toInt(), b.toInt(), c.toInt(), d.toInt(), e))
            6 -> {
                val bytes = data ?: ByteArray(0)
                val w = a.toInt(); val h = b.toInt(); val pixels = w * h * 4
                if (w <= 0 || h <= 0 || bytes.size < pixels) handler.onCursorImage(null)
                else handler.onCursorImage(CursorImage(w, h, c.toInt(), d.toInt(), bytes.copyOfRange(0, pixels), bytes.copyOfRange(pixels, bytes.size)))
            }
            7 -> handler.onCursorPosition(a.toInt(), b.toInt())
            8 -> {
                val o = obj(text)
                handler.onDisplays(
                    DisplayList(o.long("current"), o.int("framebufferWidth"), o.int("desktopWidth"), o.array("displays").map {
                        Display(it.long("displayID"), it.int("logicalWidth"), it.int("logicalHeight"), it.bool("isMain"), it.bool("isVirtual"))
                    }),
                )
            }
            9 -> handler.onClipboard(Clipboard.from(obj(text), data ?: ByteArray(0)))
            10 -> handler.onClipboardProblem(a.toInt(), text ?: "")
            11 -> handler.onBell()
            12 -> handler.onKeyboardSource(text ?: "", a.bool())
            13 -> handler.onStatus(a.toInt())
            14 -> handler.onPrompt(Prompt(a, text ?: "", b.bool(), c.bool()))
            15 -> handler.onVideoFormat(VideoFormat(a.toInt(), b.toInt(), c.toInt(), d.toInt(), e.bool(), splitLengthPrefixed(data ?: ByteArray(0))))
            16 -> {
                val o = obj(text)
                handler.onVideoAccessUnit(
                    VideoAccessUnit(
                        data ?: ByteArray(0), o.long("timestamp"), o.int("clockRate"), o.bool("sync"), o.int("band"), o.int("bands"),
                        o.long("frameID"), o.bool("frameEnd"), o.int("changedBands"), o.bool("discontinuity"), o.int("turns"),
                        o.long("holdNanoseconds"), o.bool("composed"), o.long("composeNanoseconds"),
                    ),
                )
            }
            17 -> handler.onAudioFormat(AudioFormat(a, b.toInt(), c.toInt(), d.toInt(), data ?: ByteArray(0)))
            18 -> handler.onAudioPacket(AudioPacket(data ?: ByteArray(0), a, b.toInt()))
            19 -> handler.onMicrophone(AudioFormat(a, b.toInt(), c.toInt(), d.toInt(), data ?: ByteArray(0)))
            20 -> handler.onMediaStopped(a.toInt(), text ?: "")
            21 -> handler.onFileTransferProgress(a, b, c)
            22 -> {
                val o = obj(text)
                handler.onFileTransferFinished(a, o.str("name"), b.toInt(), o.str("message"))
            }
            23 -> handler.onDropDestination(a, text ?: "")
            24 -> handler.onRemoteDrag(
                text?.let { RemoteDrag(obj(it).array("items").map { i -> RemoteDragItem(i.str("path"), i.bool("isFolder")) }, data) },
            )
            25 -> {
                val o = obj(text)
                handler.onDeviceInfo(o.str("model"), o.str("deviceColor"), o.str("enclosureColor"))
            }
        }
    }

    private fun obj(text: String?): JsonObject = if (text.isNullOrEmpty()) JsonObject(emptyMap()) else AosGo.json.parseToJsonElement(text).jsonObject

    private fun splitLengthPrefixed(data: ByteArray): List<ByteArray> {
        val units = ArrayList<ByteArray>()
        var i = 0
        while (i + 4 <= data.size) {
            val n = (data[i].toInt() and 0xff shl 24) or (data[i + 1].toInt() and 0xff shl 16) or (data[i + 2].toInt() and 0xff shl 8) or (data[i + 3].toInt() and 0xff)
            if (n < 0 || i + 4 + n > data.size) break
            units += data.copyOfRange(i + 4, i + 4 + n)
            i += 4 + n
        }
        return units
    }

    /** One JNA callback for all sessions (kept attached to the VM), dispatching by handle. */
    private object Dispatcher {
        val sessions = ConcurrentHashMap<Long, AosGoSession>()
        val callback: SessionCallback = AosGo.keepAttached(object : SessionCallback {
            override fun invoke(session: Long, kind: Int, a: Long, b: Long, c: Long, d: Long, e: Long, text: Pointer?, data: Pointer?, length: Long) {
                val target = sessions[session] ?: return
                try {
                    val string = text?.getString(0, "UTF-8")
                    val bytes = if (data != null && length > 0) data.getByteArray(0, length.toInt()) else null
                    target.event(kind, a, b, c, d, e, string, bytes)
                } catch (t: Throwable) {
                    System.err.println("aosgo: session event $kind: $t")
                }
            }
        }, "aosgo-session")
    }
}

// MARK: tailnetkit: aOS's Tailscale node

/**
 * The node's state (Tailnetkit State on Android). backendState: NoState, NeedsLogin, NeedsMachineAuth, Stopped,
 * Starting, Running. authURL is the sign-in page while needed (left out of toString on purpose).
 */
data class TailnetState(
    val backendState: String, val isRunning: Boolean, val needsLogin: Boolean, val authURL: String, val tailnet: String,
    val magicDNSSuffix: String, val dnsName: String, val addresses: String, val keyExpiry: String, val health: String,
    val error: String,
) {
    override fun toString() = "TailnetState(backendState=$backendState, tailnet=$tailnet, dnsName=$dnsName, addresses=$addresses, error=$error)"

    companion object {
        internal fun from(o: JsonObject) = TailnetState(
            o.str("backendState"), o.bool("running"), o.bool("needsLogin"), o.str("authURL"), o.str("tailnet"),
            o.str("magicDNSSuffix"), o.str("dnsName"), o.str("addresses"), o.str("keyExpiry"), o.str("health"), o.str("error"),
        )
    }
}

/**
 * aOS's own Tailscale node (Tailnetkit.newNode on Android). dir: absolute, the node's state (created 0700; out of
 * backups); hostname: a DNS label ("aos-<device name>"); controlURL "" = Tailscale's server; logger: the node's
 * verbose log or null. Methods block (up to 10 to 20 seconds, dial up to its timeout): call them off the UI thread.
 */
class TailnetNode(dir: String, hostname: String, controlURL: String = "", logger: ((String) -> Unit)? = null) : AutoCloseable {
    private val lib = AosGo.library
    private val logger = logger
    @Volatile private var listener: ((TailnetState) -> Unit)? = null
    val handle: Long

    init {
        handle = AosGo.handle { lib.aosgo_tailnet_new(dir, hostname, controlURL, if (logger == null) null else NodeDispatcher.log, it) }
        NodeDispatcher.nodes[handle] = this // log lines from before (handle 0) are dropped
    }

    /** Starts without waiting; states go to listener (on a Go thread, one at a time). A second start does nothing. */
    fun start(listener: ((TailnetState) -> Unit)?) {
        this.listener = listener
        AosGo.status { lib.aosgo_tailnet_start(handle, if (listener == null) null else NodeDispatcher.state, it) }
    }

    fun state(): TailnetState = TailnetState.from(AosGo.jsonCall { lib.aosgo_tailnet_state(handle, it) })
    fun statusJSON(): String = AosGo.stringCall { lib.aosgo_tailnet_status_json(handle, it) }
    fun login() = AosGo.status { lib.aosgo_tailnet_login(handle, it) }
    fun logout() = AosGo.status { lib.aosgo_tailnet_logout(handle, it) }

    /**
     * Connects to host:port through the tailnet and returns a port on 127.0.0.1 that takes one connection within 15
     * seconds (only from clientPort if > 0). The safe way: bind a Socket to 127.0.0.1:0, pass its localPort, then
     * connect it to 127.0.0.1:<returned port> (third_party/README.md, "tailnetkit").
     */
    fun dial(host: String, port: Int, timeoutMillis: Int, clientPort: Int): Int =
        AosGo.handle { lib.aosgo_tailnet_dial(handle, host, port, timeoutMillis, clientPort, it).toLong() }.toInt()

    /** Idempotent; also from inside the listener. */
    override fun close() {
        NodeDispatcher.nodes.remove(handle)
        lib.aosgo_tailnet_close(handle)
    }

    companion object {
        fun builtForAOS(): Boolean = AosGo.library.aosgo_tailnet_built_for_aos() != 0

        /** https and tailscale.com / *.tailscale.com: only those sign-in pages should open. */
        fun isSignInPage(url: String): Boolean = AosGo.library.aosgo_tailnet_is_sign_in_page(url) != 0
    }

    private object NodeDispatcher {
        val nodes = ConcurrentHashMap<Long, TailnetNode>()
        val log: TailnetLogCallback = AosGo.keepAttached(object : TailnetLogCallback {
            override fun invoke(node: Long, line: Pointer?) {
                val target = nodes[node] ?: return
                runCatching { target.logger?.invoke(line?.getString(0, "UTF-8") ?: "") }
            }
        }, "aosgo-tailnet-log")
        val state: TailnetStateCallback = AosGo.keepAttached(object : TailnetStateCallback {
            override fun invoke(node: Long, stateJSON: Pointer?) {
                val target = nodes[node] ?: return
                val listener = target.listener ?: return
                try {
                    listener(TailnetState.from(AosGo.json.parseToJsonElement(stateJSON?.getString(0, "UTF-8") ?: "{}").jsonObject))
                } catch (t: Throwable) {
                    System.err.println("aosgo: tailnet state: $t")
                }
            }
        }, "aosgo-tailnet")
    }
}
