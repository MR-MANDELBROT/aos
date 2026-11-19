// The desktop Go library (third_party/aosgo-desktop: libsharing + tailnetkit, GPL-3.0) behind aOS's interfaces: the
// screen's RemoteSession (ported from Android's src/libsharing LibsharingSession.kt, itself Open Screen Sharing's
// LibsharingSession.swift, GPL-3.0, nekohasekai) and aOS's own Tailscale node (Android's src/tailnet Tailnets.kt). Only
// compiled when the binding is there (desktop/build.gradle.kts); src/noaosgo has the stand-in.

package dev.marquart.aos.desktop

import dev.marquart.aos.connection.NoTailnet
import dev.marquart.aos.connection.TailnetConnection
import dev.marquart.aos.connection.TailnetDialer
import dev.marquart.aos.desktop.native.AosGo
import dev.marquart.aos.desktop.native.AosGoSession
import dev.marquart.aos.desktop.native.Clipboard
import dev.marquart.aos.desktop.native.ClipboardFlavor
import dev.marquart.aos.desktop.native.ClipboardItem
import dev.marquart.aos.desktop.native.CursorImage
import dev.marquart.aos.desktop.native.DisplayList
import dev.marquart.aos.desktop.native.Framebuffer as GoFramebuffer
import dev.marquart.aos.desktop.native.FramebufferUpdate
import dev.marquart.aos.desktop.native.HighPerformanceOptions
import dev.marquart.aos.desktop.native.Libsharing
import dev.marquart.aos.desktop.native.Prompt
import dev.marquart.aos.desktop.native.ServerInfo
import dev.marquart.aos.desktop.native.SessionHandler
import dev.marquart.aos.desktop.native.SessionOptions
import dev.marquart.aos.desktop.native.TailnetNode
import dev.marquart.aos.desktop.native.TailnetState
import dev.marquart.aos.desktop.native.VideoAccessUnit
import dev.marquart.aos.desktop.native.VideoFormat
import dev.marquart.aos.screen.CursorData
import dev.marquart.aos.screen.DisplayMode
import dev.marquart.aos.screen.FailureKind
import dev.marquart.aos.screen.Framebuffer
import dev.marquart.aos.screen.GesturePhase
import dev.marquart.aos.screen.HighPerformanceRequest
import dev.marquart.aos.screen.LoginCheckResult
import dev.marquart.aos.screen.MacKey
import dev.marquart.aos.screen.MediaFailureKind
import dev.marquart.aos.screen.PointerButton
import dev.marquart.aos.screen.RemoteSession
import dev.marquart.aos.screen.RemoteSessionFactory
import dev.marquart.aos.screen.RemoteSessionListener
import dev.marquart.aos.screen.RemoteSessionOptions
import dev.marquart.aos.screen.RemoteState
import dev.marquart.aos.screen.ServerInfoData
import dev.marquart.aos.screen.SessionChoice
import dev.marquart.aos.screen.SessionFailure
import dev.marquart.aos.screen.SessionPrompt
import dev.marquart.aos.screen.SystemCommand
import dev.marquart.aos.screen.VideoCodec
import dev.marquart.aos.screen.VideoFormatInfo
import dev.marquart.aos.screen.VideoUnit
import dev.marquart.aos.ui.tailnet.TailnetControl
import dev.marquart.aos.ui.tailnet.TailnetInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.runInterruptible
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.concurrent.thread

/** Built with the desktop Go library's binding. The library itself is loaded at first use (it may be missing). */
object GoLibrary {
    /** The library loads (it ships next to the jar in the packages: `aosgo.library`, see the launchers). */
    val AVAILABLE: Boolean by lazy {
        runCatching { AosGo.library; true }.getOrElse {
            System.err.println("aOS: the Go library (aosgo) isn't there: ${it.message}")
            false
        }
    }

    fun tailnet(deviceName: String): TailnetDialer =
        if (AVAILABLE) DesktopTailnet(File(Os.configDir, "Tailnet"), DesktopTailnet.hostname(deviceName)) else NoTailnet

    fun tailnetControl(dialer: TailnetDialer): TailnetControl? = (dialer as? DesktopTailnet)?.let(::DesktopTailnetControl)

    val screenSessions: RemoteSessionFactory = object : RemoteSessionFactory {
        override val available: Boolean get() = AVAILABLE

        override fun create(options: RemoteSessionOptions, listener: RemoteSessionListener): RemoteSession {
            if (!AVAILABLE) throw UnsupportedOperationException("The screen sharing library (aosgo) isn't there.")
            return GoRemoteSession(options, listener)
        }

        override fun checkLogin(options: RemoteSessionOptions): LoginCheckResult {
            if (!AVAILABLE) return LoginCheckResult.Failed("The screen sharing library (aosgo) isn't there.")
            val check = runCatching { AosGo.checkLogin(GoRemoteSession.sessionOptions(options)) }
                .getOrElse { return LoginCheckResult.Failed(it.message ?: "") }
            return when (check.errorCode) {
                Libsharing.ErrorNone -> LoginCheckResult.Ok(check.supportsHighPerformance, check.fingerprint, check.security)
                Libsharing.ErrorAuthentication -> LoginCheckResult.LoginRefused
                else -> LoginCheckResult.Failed(check.errorMessage.ifEmpty { "error ${check.errorCode}" })
            }
        }
    }
}

/** aOS's own Tailscale node on the desktop (Android's EmbeddedTailnet, the same rules: third_party/README.md). */
class DesktopTailnet(private val dir: File, private val hostname: String) : TailnetDialer {
    private var node: TailnetNode? = null
    private val _state = MutableStateFlow<TailnetState?>(null)
    private val _ready = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    val state: StateFlow<TailnetState?> = _state

    override val isSetUp: Boolean get() = dir.isDirectory
    override val isRunning: Boolean get() = _state.value?.isRunning == true
    override val ready: Flow<Unit> = _ready.asSharedFlow()

    override fun startIfSetUp() {
        if (isSetUp) setUp()
    }

    @Synchronized fun setUp() {
        if (node != null) return
        thread(name = "aos-tailnet-start", isDaemon = true) {
            try {
                Os.privateDir(dir)
                val created = TailnetNode(dir.absolutePath, hostname, "", null)
                synchronized(this) { node = created }
                created.start { state ->
                    val wasRunning = _state.value?.isRunning == true
                    _state.value = state
                    if (state.isRunning && !wasRunning) _ready.tryEmit(Unit)
                }
            } catch (_: Exception) {
                synchronized(this) { node = null }
            }
        }
    }

    fun login() {
        val current = synchronized(this) { node } ?: return setUp()
        thread(name = "aos-tailnet-login", isDaemon = true) { runCatching { current.login() } }
    }

    fun reconnect() {
        val current = synchronized(this) { node.also { node = null } }
        current?.close()
        _state.value = null
        setUp()
    }

    fun signOut() {
        val current = synchronized(this) { node.also { node = null } }
        runCatching { current?.logout() }
        current?.close()
        _state.value = null
        dir.deleteRecursively()
    }

    override suspend fun dial(host: String, port: Int, timeoutMillis: Long): TailnetConnection {
        val node = synchronized(this) { node } ?: throw IOException("aOS's Tailscale doesn't run")
        val loopback = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
        val socket = Socket()
        try {
            socket.bind(InetSocketAddress(loopback, 0))
            val local = runInterruptible(Dispatchers.IO) { node.dial(host, port, timeoutMillis.toInt(), socket.localPort) }
            runInterruptible(Dispatchers.IO) { socket.connect(InetSocketAddress(loopback, local), 5_000) }
            socket.tcpNoDelay = true
        } catch (e: Exception) {
            socket.close()
            throw if (e is IOException) e else IOException(e.message, e)
        }
        return object : TailnetConnection {
            override val input: InputStream = socket.getInputStream()
            override val output: OutputStream = socket.getOutputStream()
            override fun close() = socket.close()
        }
    }

    companion object {
        /** `aos-<computer name>` as a DNS label. */
        fun hostname(deviceName: String): String {
            val label = deviceName.lowercase().map { if (it in 'a'..'z' || it in '0'..'9') it else '-' }.joinToString("")
                .split('-').filter { it.isNotEmpty() }.joinToString("-")
            return ("aos-" + label.ifEmpty { "desktop" }).take(63).trimEnd('-')
        }
    }
}

private class DesktopTailnetControl(private val node: DesktopTailnet) : TailnetControl {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override val info: StateFlow<TailnetInfo?> = node.state.map { s ->
        s?.let {
            TailnetInfo(
                backendState = it.backendState, tailnet = it.tailnet, dnsName = it.dnsName.trimEnd('.'),
                addresses = TailnetInfo.addresses(it.addresses), keyExpiry = it.keyExpiry, error = it.error,
                authUrl = it.authURL.takeIf { url -> url.isNotEmpty() }, isRunning = it.isRunning, needsLogin = it.needsLogin,
            )
        }
    }.stateIn(scope, SharingStarted.Eagerly, null)

    override val isSetUp: Boolean get() = node.isSetUp
    override fun setUp() = node.setUp()
    override fun signIn() = node.login()
    override fun reconnect() = node.reconnect()
    override fun signOut() = node.signOut()
}

/** libsharing's session behind aOS's RemoteSession (Android's LibsharingRemoteSession with the desktop binding). */
private class GoRemoteSession(options: RemoteSessionOptions, private val listener: RemoteSessionListener) : RemoteSession, SessionHandler {
    private val session = AosGoSession(sessionOptions(options), this)
    @Volatile private var framebufferFailure: String? = null
    @Volatile private var started = false
    @Volatile private var fingerprint = ""

    companion object {
        fun sessionOptions(options: RemoteSessionOptions) = SessionOptions(
            host = options.host, port = options.port, username = options.username, password = options.password ?: "",
            protocol = Libsharing.ProtocolRFB, platform = Libsharing.PlatformMac,
            loginType = if (options.password == null) Libsharing.LoginNone else Libsharing.LoginAccount,
            trustedFingerprint = options.trustedFingerprint, requireTrustedKey = options.requireTrustedKey,
            allowUnverifiedLogin = options.allowUnverifiedLogin,
            quality = if (options.fullQuality) Libsharing.QualityFull else Libsharing.QualityAdaptive, mode = Libsharing.ModeControl,
            sharedClipboard = options.sharedClipboard, clientName = options.clientName, decoderMaxPixelRate = options.decoderMaxPixelRate,
            audio = false, microphone = false, keepAlive = true, cacheDirectory = options.cacheDirectory,
        )
    }

    private inline fun attempt(block: () -> Unit) {
        try {
            block()
        } catch (_: Exception) {
        }
    }

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
        if (code == null) session.sendKey(key.keysym, down) else session.sendKeyCode(code, Libsharing.KeyboardANSI, key.keysym, down)
    }

    override fun sendText(text: String) = attempt { session.sendText(text) }
    override fun pasteText(text: String) = attempt { session.pasteText(text) }

    override fun sendSystemCommand(command: SystemCommand) = attempt {
        session.sendSystemCommand(when (command) {
            SystemCommand.MISSION_CONTROL -> Libsharing.SystemCommandMissionControl
            SystemCommand.APP_WINDOWS -> Libsharing.SystemCommandAppWindows
            SystemCommand.SHOW_DESKTOP -> Libsharing.SystemCommandShowDesktop
            SystemCommand.LAUNCHPAD -> Libsharing.SystemCommandLaunchpad
        })
    }

    override fun setClipboardText(text: String) = attempt {
        session.setClipboard(Clipboard(listOf(ClipboardItem(listOf(ClipboardFlavor(Libsharing.UTF8PlainText, text.toByteArray()))))))
    }

    override fun requestClipboard() = attempt { session.requestClipboard() }
    override fun setSharedClipboard(enabled: Boolean) = attempt { session.setSharedClipboard(enabled) }
    override fun setVirtualDisplay(mode: DisplayMode, largestSide: Int) = attempt {
        session.setVirtualDisplay(mode.width, mode.height, mode.density.toDouble(), largestSide, largestSide)
    }

    override fun startHighPerformance(request: HighPerformanceRequest) {
        var codecs = 0
        if (VideoCodec.HEVC in request.codecs) codecs = codecs or Libsharing.DecoderCodecHEVC
        if (VideoCodec.H264 in request.codecs) codecs = codecs or Libsharing.DecoderCodecH264
        try {
            session.startHighPerformance(HighPerformanceOptions(supportedCodecs = codecs, pixelFormats = (1 shl 0) or (1 shl 1),
                audio = request.audio, bands = request.bands,
                videoMode = if (request.coreDevice) Libsharing.VideoModeCoreDevice else Libsharing.VideoModeRemoteDesktop))
        } catch (e: Exception) {
            listener.onMediaStopped(MediaFailureKind.OTHER, e.message ?: "")
        }
    }

    override fun requestKeyframe() = attempt { session.requestKeyframe() }
    override fun requestRefresh() = attempt { session.requestRefresh() }
    override fun setFullQuality(full: Boolean) = attempt { session.setQuality(if (full) Libsharing.QualityFull else Libsharing.QualityAdaptive) }
    override fun setVisible(visible: Boolean) = attempt { session.setVisible(visible) }
    override fun answerPrompt(id: Long, choice: SessionChoice) = attempt {
        session.answerPrompt(id, when (choice) {
            SessionChoice.SHARE_CONSOLE -> Libsharing.SessionChoiceShareConsole
            SessionChoice.OWN_SESSION -> Libsharing.SessionChoiceOwnSession
            SessionChoice.CANCEL -> Libsharing.SessionChoiceCancel
        })
    }

    override val displayWidthMultiple: Int get() = runCatching { session.displayWidthMultiple().coerceAtLeast(1) }.getOrDefault(1)

    private fun phase(phase: GesturePhase): Int = when (phase) {
        GesturePhase.MAY_BEGIN -> Libsharing.GesturePhaseMayBegin
        GesturePhase.BEGAN -> Libsharing.GesturePhaseBegan
        GesturePhase.CHANGED -> Libsharing.GesturePhaseChanged
        GesturePhase.ENDED -> Libsharing.GesturePhaseEnded
        GesturePhase.CANCELLED -> Libsharing.GesturePhaseCancelled
    }

    // SessionHandler (libsharing's threads)

    override fun onStateChanged(state: Int, errorCode: Int, message: String) {
        when (state) {
            Libsharing.StateConnecting -> listener.onState(RemoteState.CONNECTING, null)
            Libsharing.StateAuthenticating -> listener.onState(RemoteState.AUTHENTICATING, null)
            Libsharing.StateWaitingForApproval -> listener.onState(RemoteState.WAITING_FOR_APPROVAL, null)
            Libsharing.StateChoosingSession -> Unit
            Libsharing.StateConnected -> listener.onState(RemoteState.CONNECTED, null)
            Libsharing.StateDisconnected -> {
                val text = framebufferFailure ?: message
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
            }
        }
    }

    override fun onServerInfo(info: ServerInfo) {
        listener.onServerInfo(ServerInfoData(
            width = info.width, height = info.height, apple = info.dialect == Libsharing.DialectApple, observeOnly = info.observeOnly,
            virtualDisplay = info.supportsVirtualDisplay, highPerformance = info.supportsHighPerformance, clipboard = info.supportsClipboard,
            clipboardRequest = info.supportsClipboardRequest, keyboardSource = info.supportsKeyboardSource, keyCodes = info.supportsKeyCodes,
            gestures = info.supportsGestures, missionControl = info.supportsMissionControl, appWindows = info.supportsAppWindows,
            showDesktop = info.supportsShowDesktop, launchpad = info.supportsLaunchpad, quality = info.supportsQuality,
            unicodeText = info.supportsUnicodeText,
        ))
    }

    override fun onServerCertificate(fingerprint: String) {
        this.fingerprint = fingerprint
        listener.onFingerprint(fingerprint)
    }

    override fun onFramebufferResize(session: AosGoSession, width: Int, height: Int) {
        try {
            val fb = GoFramebuffer(width, height)
            session.attachFramebuffer(fb)
            framebufferFailure = null
            started = true
            listener.onFramebuffer(Framebuffer(fb.memory.getByteBuffer(0, fb.bytesPerRow.toLong() * height), width, height, fb.bytesPerRow))
        } catch (e: Throwable) {
            framebufferFailure = "attach a ${width}x$height framebuffer: ${e.message}"
        }
    }

    override fun onFramebufferUpdate(update: FramebufferUpdate) = listener.onFramebufferUpdate(update.x, update.y, update.width, update.height)

    override fun onCursorImage(cursor: CursorImage?) {
        if (cursor == null || cursor.width <= 0 || cursor.height <= 0 || cursor.pixels.size < cursor.width * cursor.height * 4) {
            listener.onCursor(null)
            return
        }
        listener.onCursor(CursorData(cursor.width, cursor.height, cursor.hotspotX, cursor.hotspotY, cursor.pixels))
    }

    override fun onCursorPosition(x: Int, y: Int) = listener.onCursorPosition(x, y)

    override fun onVideoFormat(format: VideoFormat) {
        listener.onVideoFormat(VideoFormatInfo(if (format.codec == Libsharing.CodecH264) VideoCodec.H264 else VideoCodec.HEVC,
            format.parameterSets, format.height, format.chromaFormat, format.hdr))
    }

    override fun onVideoAccessUnit(unit: VideoAccessUnit) =
        listener.onVideoUnit(VideoUnit(unit.data, unit.timestamp, unit.clockRate, unit.sync, unit.discontinuity))

    override fun onMediaStopped(errorCode: Int, message: String) {
        val kind = when (errorCode) {
            Libsharing.MediaErrorNone -> null
            Libsharing.MediaErrorBusy -> MediaFailureKind.BUSY
            Libsharing.MediaErrorNetwork -> MediaFailureKind.NETWORK
            Libsharing.MediaErrorRefused -> MediaFailureKind.REFUSED
            Libsharing.MediaErrorSilent -> MediaFailureKind.SILENT
            else -> MediaFailureKind.OTHER
        }
        listener.onMediaStopped(kind, message)
    }

    override fun onDisplays(displays: DisplayList) {
        val selected = displays.displays.firstOrNull { it.displayID == displays.current }
        val pointsWide = selected?.logicalWidth ?: displays.desktopWidth
        if (displays.framebufferWidth > 0 && pointsWide > 0) listener.onPointsPerPixel(pointsWide.toDouble() / displays.framebufferWidth)
    }

    override fun onClipboard(clipboard: Clipboard) {
        clipboard.text()?.let(listener::onClipboardText)
    }

    override fun onKeyboardSource(sourceID: String, secureInput: Boolean) = listener.onKeyboardSource(sourceID, secureInput)

    override fun onStatus(status: Int) {
        when (status) {
            Libsharing.StatusControlAllowed -> listener.onControlAllowed(true)
            Libsharing.StatusObserveOnly -> listener.onControlAllowed(false)
            Libsharing.StatusPointerHidden -> listener.onPointerVisible(false)
            Libsharing.StatusPointerShown -> listener.onPointerVisible(true)
        }
    }

    override fun onPrompt(prompt: Prompt) =
        listener.onPrompt(SessionPrompt(prompt.promptID, prompt.consoleUser, prompt.allowsShareConsole, prompt.allowsOwnSession))

    override fun onDeviceInfo(model: String, deviceColor: String, enclosureColor: String) {
        fun known(v: String) = if (v.equals("unknown", true)) "" else v
        val m = known(model)
        if (m.isEmpty()) return
        listener.onDeviceInfo(m, known(enclosureColor).ifEmpty { known(deviceColor) })
    }
}
