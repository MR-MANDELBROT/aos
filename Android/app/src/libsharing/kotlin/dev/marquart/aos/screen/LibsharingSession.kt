// Based on Open Screen Sharing by nekohasekai (GPL-3.0); Android/app/src/main/assets/open-screen-sharing/LICENSE,
// COPYING. Ported for aOS's Android app on 2026-11-19 from iOS/ThirdParty/OpenScreenSharing
// (Session/LibsharingSession.swift, ServerProbe.swift): libsharing's session (third_party/aosgo, GPL-3.0) behind
// aOS's RemoteSession. Only compiled with the Go library (app/build.gradle.kts).

package dev.marquart.aos.screen

import android.util.Log
import dev.marquart.aos.libsharing.AudioFormat
import dev.marquart.aos.libsharing.AudioPacket
import dev.marquart.aos.libsharing.Clipboard
import dev.marquart.aos.libsharing.CursorImage
import dev.marquart.aos.libsharing.DirectFramebuffer
import dev.marquart.aos.libsharing.DisplayList
import dev.marquart.aos.libsharing.FramebufferUpdate
import dev.marquart.aos.libsharing.Libsharing
import dev.marquart.aos.libsharing.LogHandler
import dev.marquart.aos.libsharing.Prompt
import dev.marquart.aos.libsharing.RemoteDrag
import dev.marquart.aos.libsharing.ServerInfo
import dev.marquart.aos.libsharing.Session
import dev.marquart.aos.libsharing.SessionHandler
import dev.marquart.aos.libsharing.SessionOptions
import dev.marquart.aos.libsharing.ProbeRequest
import dev.marquart.aos.libsharing.VideoAccessUnit
import dev.marquart.aos.libsharing.VideoFormat
import java.util.concurrent.atomic.AtomicBoolean

/** The factory the app uses (src/nolibsharing has one that reports itself unavailable). */
object RemoteSessions {
    val factory: RemoteSessionFactory = LibsharingFactory
}

private object LibsharingFactory : RemoteSessionFactory {
    private const val TAG = "libsharing"
    private val logInstalled = AtomicBoolean(false)

    override val available: Boolean get() = true

    /** libsharing's log to logcat (info and up). Host names may be in it; it stays on the phone. */
    fun installLog() {
        if (!logInstalled.compareAndSet(false, true)) return
        Libsharing.setLogHandler(LogHandler { level, message ->
            when {
                level >= 8 -> Log.e(TAG, message)
                level >= 4 -> Log.w(TAG, message)
                else -> Log.i(TAG, message)
            }
        }, 0)
    }

    override fun create(options: RemoteSessionOptions, listener: RemoteSessionListener): RemoteSession {
        installLog()
        return LibsharingRemoteSession(options, listener)
    }

    override fun checkLogin(options: RemoteSessionOptions): LoginCheckResult {
        installLog()
        val check = ProbeRequest().checkLogin(LibsharingRemoteSession.sessionOptions(options))
        return when (check.errorCode) {
            Libsharing.ErrorNone -> LoginCheckResult.Ok(check.supportsHighPerformance, check.fingerprint ?: "", check.security ?: "")
            Libsharing.ErrorAuthentication -> LoginCheckResult.LoginRefused
            else -> LoginCheckResult.Failed(check.errorMessage ?: "error ${check.errorCode}")
        }
    }
}

private class LibsharingRemoteSession(
    options: RemoteSessionOptions,
    private val listener: RemoteSessionListener,
) : RemoteSession, SessionHandler {
    private val session: Session = Libsharing.newSession(sessionOptions(options), this)

    // The framebuffer libsharing writes into: kept until the next one is attached and its resize returned, or until the
    // session ends (the DirectFramebuffer contract).
    @Volatile private var framebuffer: DirectFramebuffer? = null
    @Volatile private var previousFramebuffer: DirectFramebuffer? = null
    @Volatile private var framebufferFailure: String? = null
    @Volatile private var started = false
    @Volatile private var fingerprint = ""

    companion object {
        const val UTF8_TEXT = "public.utf8-plain-text"

        fun sessionOptions(options: RemoteSessionOptions): SessionOptions = Libsharing.newSessionOptions().apply {
            protocol = Libsharing.ProtocolRFB
            platform = Libsharing.PlatformMac
            host = options.host
            port = options.port
            username = options.username
            if (options.password == null) {
                loginType = Libsharing.LoginNone
            } else {
                loginType = Libsharing.LoginAccount
                password = options.password
            }
            trustedFingerprint = options.trustedFingerprint
            requireTrustedKey = options.requireTrustedKey
            allowUnverifiedLogin = options.allowUnverifiedLogin
            quality = if (options.fullQuality) Libsharing.QualityFull else Libsharing.QualityAdaptive
            mode = Libsharing.ModeControl
            sharedClipboard = options.sharedClipboard
            clientName = options.clientName
            decoderMaxPixelRate = options.decoderMaxPixelRate
            audio = false
            microphone = false
            keepAlive = true
            if (options.cacheDirectory.isNotEmpty()) cacheDirectory = options.cacheDirectory
        }
    }

    private inline fun attempt(block: () -> Unit) {
        try {
            block()
        } catch (_: Exception) {
        }
    }

    // RemoteSession

    override fun connect() {
        try {
            session.connect()
        } catch (e: Exception) {
            listener.onState(RemoteState.DISCONNECTED, SessionFailure(FailureKind.UNREACHABLE, e.message ?: ""))
        }
    }

    override fun disconnect() = session.disconnect()
    override fun abort() = session.abort()
    override fun sendPointer(x: Int, y: Int, buttons: Int, clickCount: Int) = attempt {
        var mask = 0
        if (buttons and PointerButton.PRIMARY != 0) mask = mask or Libsharing.ButtonLeft
        if (buttons and PointerButton.MIDDLE != 0) mask = mask or Libsharing.ButtonMiddle
        if (buttons and PointerButton.SECONDARY != 0) mask = mask or Libsharing.ButtonRight
        session.sendPointer(x, y, mask, clickCount)
    }

    override fun sendScroll(x: Int, y: Int, dx: Double, dy: Double) = attempt { session.sendScroll(x, y, dx, dy) }
    override fun sendScrollPhase(x: Int, y: Int, dx: Double, dy: Double, phase: GesturePhase) =
        attempt { session.sendScrollPhase(x, y, dx, dy, phase(phase)) }

    override fun startScrollMomentum(x: Int, y: Int, vx: Double, vy: Double) = attempt { session.startScrollMomentum(x, y, vx, vy) }
    override fun stopScrollMomentum() = session.stopScrollMomentum()

    override fun sendKey(key: MacKey, down: Boolean) = attempt {
        val code = key.keyCode
        if (code == null) session.sendKey(key.keysym, down)
        else session.sendKeyCode(code, Libsharing.KeyboardANSI, key.keysym, down)
    }

    override fun sendText(text: String) = attempt { session.sendText(text) }
    override fun pasteText(text: String) = attempt { session.pasteText(text) }

    override fun sendSystemCommand(command: SystemCommand) = attempt {
        session.sendSystemCommand(
            when (command) {
                SystemCommand.MISSION_CONTROL -> Libsharing.SystemCommandMissionControl
                SystemCommand.APP_WINDOWS -> Libsharing.SystemCommandAppWindows
                SystemCommand.SHOW_DESKTOP -> Libsharing.SystemCommandShowDesktop
                SystemCommand.LAUNCHPAD -> Libsharing.SystemCommandLaunchpad
            },
        )
    }

    override fun setClipboardText(text: String) = attempt {
        val item = Libsharing.newClipboardItem()
        item.addFlavor(UTF8_TEXT, text.toByteArray())
        val clipboard = Libsharing.newClipboard()
        clipboard.addItem(item)
        session.setClipboard(clipboard)
    }

    override fun requestClipboard() = attempt { session.requestClipboard() }
    override fun setSharedClipboard(enabled: Boolean) = attempt { session.setSharedClipboard(enabled) }

    override fun setVirtualDisplay(mode: DisplayMode, largestSide: Int) = attempt {
        session.setVirtualDisplay(mode.width, mode.height, mode.density.toDouble(), largestSide, largestSide)
    }

    override fun startHighPerformance(request: HighPerformanceRequest) {
        val hp = Libsharing.newHighPerformanceOptions()
        var codecs = 0
        if (VideoCodec.HEVC in request.codecs) codecs = codecs or Libsharing.DecoderCodecHEVC
        if (VideoCodec.H264 in request.codecs) codecs = codecs or Libsharing.DecoderCodecH264
        hp.supportedCodecs = codecs
        hp.pixelFormats = (1 shl 0) or (1 shl 1)
        hp.bands = request.bands
        hp.videoMode = if (request.coreDevice) Libsharing.VideoModeCoreDevice else Libsharing.VideoModeRemoteDesktop
        hp.audio = request.audio
        try {
            session.startHighPerformance(hp)
        } catch (e: Exception) {
            listener.onMediaStopped(MediaFailureKind.OTHER, e.message ?: "")
        }
    }

    override fun requestKeyframe() = attempt { session.requestKeyframe() }
    override fun requestRefresh() = attempt { session.requestRefresh() }
    override fun setFullQuality(full: Boolean) = attempt { session.setQuality(if (full) Libsharing.QualityFull else Libsharing.QualityAdaptive) }
    override fun setVisible(visible: Boolean) = attempt { session.setVisible(visible) }
    override fun answerPrompt(id: Long, choice: SessionChoice) = attempt {
        session.answerPrompt(
            id,
            when (choice) {
                SessionChoice.SHARE_CONSOLE -> Libsharing.SessionChoiceShareConsole
                SessionChoice.OWN_SESSION -> Libsharing.SessionChoiceOwnSession
                SessionChoice.CANCEL -> Libsharing.SessionChoiceCancel
            },
        )
    }

    override val displayWidthMultiple: Int get() = try { session.displayWidthMultiple().coerceAtLeast(1) } catch (_: Exception) { 1 }

    private fun phase(phase: GesturePhase): Int = when (phase) {
        GesturePhase.MAY_BEGIN -> Libsharing.GesturePhaseMayBegin
        GesturePhase.BEGAN -> Libsharing.GesturePhaseBegan
        GesturePhase.CHANGED -> Libsharing.GesturePhaseChanged
        GesturePhase.ENDED -> Libsharing.GesturePhaseEnded
        GesturePhase.CANCELLED -> Libsharing.GesturePhaseCancelled
    }

    // SessionHandler (libsharing's threads)

    override fun onStateChanged(state: Int, errorCode: Int, message: String?) {
        when (state) {
            Libsharing.StateConnecting -> listener.onState(RemoteState.CONNECTING, null)
            Libsharing.StateAuthenticating -> listener.onState(RemoteState.AUTHENTICATING, null)
            Libsharing.StateWaitingForApproval -> listener.onState(RemoteState.WAITING_FOR_APPROVAL, null)
            Libsharing.StateChoosingSession -> Unit
            Libsharing.StateConnected -> listener.onState(RemoteState.CONNECTED, null)
            Libsharing.StateDisconnected -> {
                val text = framebufferFailure ?: message ?: ""
                val failure = when (errorCode) {
                    Libsharing.ErrorNone, Libsharing.ErrorCancelled -> null
                    Libsharing.ErrorAuthentication -> SessionFailure(FailureKind.AUTHENTICATION, text)
                    Libsharing.ErrorPermissionDenied -> SessionFailure(FailureKind.PERMISSION_DENIED, text)
                    Libsharing.ErrorHostNotFound -> SessionFailure(FailureKind.HOST_NOT_FOUND, text)
                    Libsharing.ErrorOwnScreen -> SessionFailure(FailureKind.OWN_SCREEN, text)
                    Libsharing.ErrorNetwork -> SessionFailure(if (started) FailureKind.CONNECTION_LOST else FailureKind.UNREACHABLE, text)
                    Libsharing.ErrorSessionEnded -> SessionFailure(FailureKind.CLOSED_BY_SERVER, text)
                    Libsharing.ErrorUnsupportedServer -> SessionFailure(FailureKind.UNSUPPORTED, text)
                    Libsharing.ErrorCertificateChanged -> SessionFailure(FailureKind.CERTIFICATE_CHANGED, text, fingerprint = fingerprint)
                    Libsharing.ErrorUnverifiedServer -> SessionFailure(FailureKind.UNVERIFIED_SERVER, text)
                    else -> SessionFailure(if (started) FailureKind.ENDED else FailureKind.OTHER, text)
                }
                listener.onState(RemoteState.DISCONNECTED, failure)
                framebuffer = null
                previousFramebuffer = null
            }
        }
    }

    override fun onServerInfo(info: ServerInfo?) {
        info ?: return
        listener.onServerInfo(
            ServerInfoData(
                width = info.width, height = info.height, apple = info.dialect == Libsharing.DialectApple,
                observeOnly = info.observeOnly, virtualDisplay = info.supportsVirtualDisplay,
                highPerformance = info.supportsHighPerformance, clipboard = info.supportsClipboard,
                clipboardRequest = info.supportsClipboardRequest, keyboardSource = info.supportsKeyboardSource,
                keyCodes = info.supportsKeyCodes, gestures = info.supportsGestures,
                missionControl = info.supportsMissionControl, appWindows = info.supportsAppWindows,
                showDesktop = info.supportsShowDesktop, launchpad = info.supportsLaunchpad, quality = info.supportsQuality,
                unicodeText = info.supportsUnicodeText,
            ),
        )
    }

    override fun onServerCertificate(fingerprint: String?) {
        this.fingerprint = fingerprint ?: ""
        listener.onFingerprint(this.fingerprint)
    }

    override fun onFramebufferResize(width: Int, height: Int) {
        try {
            val fb = DirectFramebuffer(width, height)
            fb.attachTo(session)
            previousFramebuffer = framebuffer
            framebuffer = fb
            framebufferFailure = null
            started = true
            listener.onFramebuffer(Framebuffer(fb.pixels, fb.width, fb.height, fb.bytesPerRow))
        } catch (e: Throwable) {
            framebufferFailure = "attach a ${width}x$height framebuffer: ${e.message}"
            Log.e("aos-screen", framebufferFailure!!)
        }
    }

    override fun onFramebufferUpdate(update: FramebufferUpdate?) {
        update ?: return
        listener.onFramebufferUpdate(update.x, update.y, update.width, update.height)
    }

    override fun onCursorImage(cursor: CursorImage?) {
        val pixels = cursor?.pixels
        if (cursor == null || cursor.width <= 0 || cursor.height <= 0 || pixels == null || pixels.size < cursor.width * cursor.height * 4) {
            listener.onCursor(null)
            return
        }
        listener.onCursor(CursorData(cursor.width, cursor.height, cursor.hotspotX, cursor.hotspotY, pixels))
    }

    override fun onCursorPosition(x: Int, y: Int) = listener.onCursorPosition(x, y)

    override fun onVideoFormat(format: VideoFormat?) {
        format ?: return
        val sets = (0 until format.len()).mapNotNull { format.get(it) }
        listener.onVideoFormat(
            VideoFormatInfo(if (format.codec == Libsharing.CodecH264) VideoCodec.H264 else VideoCodec.HEVC, sets, format.height,
                format.chromaFormat, format.hdr),
        )
    }

    override fun onVideoAccessUnit(unit: VideoAccessUnit?) {
        unit ?: return
        val data = unit.data ?: return
        listener.onVideoUnit(VideoUnit(data, unit.timestamp, unit.clockRate, unit.sync, unit.discontinuity))
    }

    override fun onMediaStopped(errorCode: Int, message: String?) {
        val kind = when (errorCode) {
            Libsharing.MediaErrorNone -> null
            Libsharing.MediaErrorBusy -> MediaFailureKind.BUSY
            Libsharing.MediaErrorNetwork -> MediaFailureKind.NETWORK
            Libsharing.MediaErrorRefused -> MediaFailureKind.REFUSED
            Libsharing.MediaErrorSilent -> MediaFailureKind.SILENT
            else -> MediaFailureKind.OTHER
        }
        listener.onMediaStopped(kind, message ?: "")
    }

    override fun onDisplays(displays: DisplayList?) {
        displays ?: return
        val selected = (0 until displays.len()).mapNotNull { displays.get(it) }.firstOrNull { it.displayID == displays.current }
        val pointsWide = selected?.logicalWidth ?: displays.desktopWidth
        if (displays.framebufferWidth > 0 && pointsWide > 0) listener.onPointsPerPixel(pointsWide.toDouble() / displays.framebufferWidth)
    }

    override fun onClipboard(clipboard: Clipboard?) {
        clipboard ?: return
        for (i in 0 until clipboard.len()) {
            val item = clipboard.get(i) ?: continue
            for (j in 0 until item.len()) {
                val flavor = item.get(j) ?: continue
                if (flavor.promise || flavor.type != UTF8_TEXT) continue
                val data = flavor.data ?: continue
                listener.onClipboardText(String(data))
                return
            }
        }
    }

    override fun onClipboardProblem(kind: Int, message: String?) = Unit
    override fun onBell() = Unit

    override fun onKeyboardSource(sourceID: String?, secureInput: Boolean) = listener.onKeyboardSource(sourceID ?: "", secureInput)

    override fun onStatus(status: Int) {
        when (status) {
            Libsharing.StatusControlAllowed -> listener.onControlAllowed(true)
            Libsharing.StatusObserveOnly -> listener.onControlAllowed(false)
            Libsharing.StatusPointerHidden -> listener.onPointerVisible(false)
            Libsharing.StatusPointerShown -> listener.onPointerVisible(true)
        }
    }

    override fun onPrompt(prompt: Prompt?) {
        prompt ?: return
        listener.onPrompt(SessionPrompt(prompt.promptID, prompt.consoleUser ?: "", prompt.allowsShareConsole, prompt.allowsOwnSession))
    }

    override fun onDeviceInfo(model: String?, deviceColor: String?, enclosureColor: String?) {
        fun known(v: String?) = if (v == null || v.equals("unknown", true)) "" else v
        val m = known(model)
        if (m.isEmpty()) return
        listener.onDeviceInfo(m, known(enclosureColor).ifEmpty { known(deviceColor) })
    }

    override fun onAudioFormat(format: AudioFormat?) = Unit
    override fun onAudioPacket(packet: AudioPacket?) = Unit
    override fun onMicrophone(format: AudioFormat?) = Unit
    override fun onFileTransferProgress(id: Long, transferred: Long, total: Long) = Unit
    override fun onFileTransferFinished(id: Long, name: String?, errorCode: Int, message: String?) = Unit
    override fun onDropDestination(id: Long, path: String?) = Unit
    override fun onRemoteDrag(drag: RemoteDrag?) = Unit
}
