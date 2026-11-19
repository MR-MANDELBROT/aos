// Based on Open Screen Sharing by nekohasekai (GPL-3.0); Android/app/src/main/assets/open-screen-sharing/LICENSE,
// COPYING. Ported for aOS's Android app on 2026-11-19 from iOS/ThirdParty/OpenScreenSharing (Session/RemoteSession.swift,
// LibsharingSession.swift): what a session engine offers and reports. libsharing's implementation is in
// src/libsharing (built with the Go library), a stand-in without it in src/nolibsharing.

package dev.marquart.aos.screen

import java.nio.ByteBuffer

/** Where and how one connection signs in. `password == null`: no authentication (aOS's demo server). */
data class RemoteSessionOptions(
    val host: String,
    val port: Int,
    val username: String,
    val password: String?,
    /** The screen sharing key a session must find (the key learned through SSH); empty: none known. */
    val trustedFingerprint: String = "",
    /** Only Apple's RSA login with exactly that key (aOS's direct path; libsharing's RequireTrustedKey, aOS's patch). */
    val requireTrustedKey: Boolean = false,
    val allowUnverifiedLogin: Boolean = false,
    val clientName: String = "",
    val fullQuality: Boolean = false,
    val sharedClipboard: Boolean = true,
    val cacheDirectory: String = "",
    val decoderMaxPixelRate: Long = 0,
) {
    override fun toString() = "RemoteSessionOptions(host=$host, port=$port, username=$username, password=<hidden>)"
}

/** What high performance asks for (third_party/README.md: Android's recommended options). */
data class HighPerformanceRequest(
    val codecs: Set<VideoCodec>,
    val bands: Int = 1,
    val coreDevice: Boolean = true,
    val audio: Boolean = false,
)

enum class GesturePhase { MAY_BEGIN, BEGAN, CHANGED, ENDED, CANCELLED }

enum class SessionChoice { SHARE_CONSOLE, OWN_SESSION, CANCEL }

/** libsharing's connection states. */
enum class RemoteState { CONNECTING, AUTHENTICATING, WAITING_FOR_APPROVAL, CHOOSING_SESSION, CONNECTED, DISCONNECTED }

/** Why a session failed (OSS's SessionFailure.Kind). */
enum class FailureKind {
    AUTHENTICATION, PERMISSION_DENIED, HOST_NOT_FOUND, OWN_SCREEN, UNREACHABLE, CONNECTION_LOST, CLOSED_BY_SERVER,
    UNSUPPORTED, CERTIFICATE_CHANGED, UNVERIFIED_SERVER, HIGH_PERFORMANCE, ENDED, OTHER,
}

/** Why high performance stopped (OSS's MediaFailure.Kind). */
enum class MediaFailureKind { BUSY, NETWORK, REFUSED, SILENT, UNSUPPORTED, UNDECODABLE, OTHER }

data class SessionFailure(
    val kind: FailureKind,
    val message: String,
    val media: MediaFailureKind? = null,
    /** The key the server showed (certificate changed). */
    val fingerprint: String = "",
)

/** What the server offers (libsharing's ServerInfo). */
data class ServerInfoData(
    val width: Int,
    val height: Int,
    val apple: Boolean,
    val observeOnly: Boolean,
    val virtualDisplay: Boolean,
    val highPerformance: Boolean,
    val clipboard: Boolean,
    val clipboardRequest: Boolean,
    val keyboardSource: Boolean,
    val keyCodes: Boolean,
    val gestures: Boolean,
    val missionControl: Boolean,
    val appWindows: Boolean,
    val showDesktop: Boolean,
    val launchpad: Boolean,
    val quality: Boolean,
    val unicodeText: Boolean,
)

/** The screen as libsharing writes it: 4 bytes a pixel, B, G, R, X in memory, rows `bytesPerRow` apart. */
class Framebuffer(val pixels: ByteBuffer, val width: Int, val height: Int, val bytesPerRow: Int)

/** The Mac's pointer: premultiplied B, G, R, A pixels, the hotspot. */
class CursorData(val width: Int, val height: Int, val hotspotX: Int, val hotspotY: Int, val pixels: ByteArray)

data class SessionPrompt(val id: Long, val consoleUser: String, val allowsShareConsole: Boolean, val allowsOwnSession: Boolean)

/** One connection to a screen (libsharing's Session). Thread-safe; nothing blocks. */
interface RemoteSession {
    fun connect()
    fun disconnect()
    fun abort()
    fun sendPointer(x: Int, y: Int, buttons: Int, clickCount: Int)
    fun sendScroll(x: Int, y: Int, dx: Double, dy: Double)
    fun sendScrollPhase(x: Int, y: Int, dx: Double, dy: Double, phase: GesturePhase)
    fun startScrollMomentum(x: Int, y: Int, vx: Double, vy: Double)
    fun stopScrollMomentum()
    fun sendKey(key: MacKey, down: Boolean)
    fun sendText(text: String)
    fun pasteText(text: String)
    fun sendSystemCommand(command: SystemCommand)
    fun setClipboardText(text: String)
    fun requestClipboard()
    fun setSharedClipboard(enabled: Boolean)
    fun setVirtualDisplay(mode: DisplayMode, largestSide: Int)
    fun startHighPerformance(request: HighPerformanceRequest)
    fun requestKeyframe()
    fun requestRefresh()
    fun setFullQuality(full: Boolean)
    fun setVisible(visible: Boolean)
    fun answerPrompt(id: Long, choice: SessionChoice)
    val displayWidthMultiple: Int
}

/**
 * What a session reports. `onFramebuffer` and `onFramebufferUpdate`, the video and the cursor come on libsharing's
 * threads and must not wait; the rest is posted to the main thread by the receiver.
 */
interface RemoteSessionListener {
    fun onState(state: RemoteState, failure: SessionFailure?)
    fun onServerInfo(info: ServerInfoData)
    fun onFingerprint(fingerprint: String)
    fun onFramebuffer(framebuffer: Framebuffer)
    fun onFramebufferUpdate(x: Int, y: Int, width: Int, height: Int)
    fun onCursor(cursor: CursorData?)
    fun onCursorPosition(x: Int, y: Int)
    fun onVideoFormat(format: VideoFormatInfo)
    fun onVideoUnit(unit: VideoUnit)
    fun onMediaStopped(failure: MediaFailureKind?, message: String)
    fun onClipboardText(text: String)
    fun onKeyboardSource(id: String, secureInput: Boolean)
    fun onPointerVisible(visible: Boolean)
    fun onControlAllowed(allowed: Boolean)
    fun onPrompt(prompt: SessionPrompt)
    fun onDeviceInfo(model: String, color: String)
    fun onPointsPerPixel(ratio: Double)
}

/** The setup check's answer (libsharing's LoginCheck). */
sealed class LoginCheckResult {
    data class Ok(val highPerformance: Boolean, val fingerprint: String, val security: String) : LoginCheckResult()
    data object LoginRefused : LoginCheckResult()
    data class Failed(val message: String) : LoginCheckResult()
}

interface RemoteSessionFactory {
    /** False without the Go library (a build without it). */
    val available: Boolean
    fun create(options: RemoteSessionOptions, listener: RemoteSessionListener): RemoteSession

    /** Signs in once without a session and reports the server's key and whether it offers high performance. Blocks. */
    fun checkLogin(options: RemoteSessionOptions): LoginCheckResult
}
