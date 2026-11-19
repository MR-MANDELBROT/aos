// Based on Open Screen Sharing by nekohasekai (GPL-3.0); Android/app/src/main/assets/open-screen-sharing/LICENSE,
// COPYING. Ported for aOS's Android app on 2026-11-19 from iOS/ThirdParty/OpenScreenSharing
// (Session/SessionController.swift with aOS's changes, Bridge/ScreenClient.swift): one screen session, its phases,
// reconnecting, the pointer, scrolling, clipboard, high performance and the direct path's hand-over to SSH.

package dev.marquart.aos.screen

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.ByteArrayOutputStream
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** What a session is doing (OSS's SessionPhase). */
sealed class SessionPhase {
    data object Connecting : SessionPhase()
    data object Authenticating : SessionPhase()
    data object WaitingForPermission : SessionPhase()
    data class ChoosingSession(val prompt: SessionPrompt) : SessionPhase()
    data object Connected : SessionPhase()
    data class Reconnecting(val attempt: Int) : SessionPhase()
    data object Disconnected : SessionPhase()
    data class Failed(val failure: SessionFailure) : SessionPhase()
}

/** Where a session connects and how (aOS's SessionRoute). */
data class SessionRoute(
    val screenId: String,
    val name: String,
    val host: String,
    val port: Int,
    val username: String,
    /** Null: no authentication (the demo server). */
    val password: String?,
    /** aOS shapes the picture itself (the workspace's display request). */
    val followsWindowShape: Boolean,
    /** High performance on aOS's direct path, tuned for this network; null: standard mode. */
    val highPerformance: ScreenNetwork? = null,
    val trustedFingerprint: String = "",
    val sharesClipboard: Boolean = true,
    val fullQuality: Boolean = false,
    val clientName: String = "",
    val cacheDirectory: String = "",
) {
    override fun toString() = "SessionRoute($name, $host:$port, highPerformance=$highPerformance)"
}

/** Where the picture goes (the renderer). Called on libsharing's threads for the framebuffer. */
interface PictureSink {
    fun framebufferChanged(framebuffer: Framebuffer)
    fun framebufferDirty(x: Int, y: Int, width: Int, height: Int)
    fun cursorChanged()
    fun redraw()
    /** The picture now comes as video (or no longer). */
    fun videoChanged(active: Boolean)
    /** The video picture as shown, for the card (main thread, may answer later). */
    fun captureVideo(done: (PlatformBitmap?) -> Unit) = done(null)
}

/** The phone's clipboard (text). */
interface ClipboardBridge {
    fun read(): String?
    fun write(text: String)
}

class SessionModel(
    val route: SessionRoute,
    private val factory: RemoteSessionFactory,
    /** Runs on the main thread (tests: at once). */
    private val main: (Runnable) -> Unit,
    resolutionScale: Double = DisplayMode.DEFAULT_RESOLUTION_SCALE,
) : KeyOutput {
    private fun post(block: () -> Unit) = main(Runnable(block))

    // State the UI shows (main thread)
    var phase by mutableStateOf<SessionPhase>(SessionPhase.Connecting); private set
    var hasPicture by mutableStateOf(false); private set
    var imageWidth by mutableIntStateOf(0); private set
    var imageHeight by mutableIntStateOf(0); private set
    var isVideo by mutableStateOf(false); private set
    var server by mutableStateOf<ServerInfoData?>(null); private set
    var clipboardSharing by mutableStateOf(route.sharesClipboard); private set
    var fullQuality by mutableStateOf(route.fullQuality); private set
    var resolutionScale by mutableStateOf(resolutionScale); private set
    var modifiersVersion by mutableIntStateOf(0); private set
    var alert by mutableStateOf<String?>(null)
    var secureInputNotice by mutableStateOf(false)
    var isClosed by mutableStateOf(false); private set
    var controlAllowed by mutableStateOf(true); private set

    // What aOS hears
    var onLoginRefused: (() -> Unit)? = null
    var onDirectPathFailed: ((String) -> Unit)? = null
    var onPicture: ((ByteArray) -> Unit)? = null
    var onDisplayArea: ((ScreenArea) -> Unit)? = null
    var onResolutionScale: ((Double) -> Unit)? = null
    var onFingerprint: ((String) -> Unit)? = null
    var onConnected: ((model: String) -> Unit)? = null
    var onClipboardSharing: ((Boolean) -> Unit)? = null
    var onFullQuality: ((Boolean) -> Unit)? = null
    var onClosed: (() -> Unit)? = null

    var pictureSink: PictureSink? = null
        set(value) {
            field = value
            framebuffer?.let { value?.framebufferChanged(it) }
            value?.videoChanged(isVideo)
        }
    var clipboard: ClipboardBridge? = null
    /** The on-screen keyboard forgets what it typed (the Mac's text cursor may have moved). */
    var onForgetTypedText: () -> Unit = {}

    // The picture (read by the renderer on its thread)
    @Volatile var framebuffer: Framebuffer? = null; private set
    @Volatile var cursor: CursorData? = null; private set
    @Volatile var pointerX = 0f; private set
    @Volatile var pointerY = 0f; private set
    @Volatile var pointerVisible = true; private set

    val keyboard = Keyboard(this).apply {
        isControlling = { this@SessionModel.isControlling }
        onSecureInputNotice = { secureInputNotice = true }
        onTextCursorMayHaveMoved = { onForgetTypedText() }
        onModifiersChanged = { modifiersVersion++ }
    }

    private var session: RemoteSession? = null
    private var generation = 0
    private var decoder: VideoDecoder? = null
    private var videoSurface: VideoSurface? = null
    private var hasConnected = false
    private var reconnectAttempts = 0
    private var reconnectToken = 0
    private var trustedFingerprint = route.trustedFingerprint
    private var allowUnverified = false
    private var learnedFingerprint = ""
    private var pointsPerPixel = 0.5
    private var buttons = 0
    private var clickCount = 1
    private var lastPress: Triple<Int, Pair<Float, Float>, Long>? = null
    private var clickModifiers: Set<ModifierKey> = emptySet()
    private var area: ScreenArea? = null
    private var screenPixels: Pair<Int, Int>? = null
    private var lastRemoteClipboard: String? = null
    private var lastSentClipboard: String? = null
    private var scrollRemainderX = 0.0
    private var scrollRemainderY = 0.0
    private var gliding = false
    private var model = ""
    private var stoppingVideo = false

    val usesHighPerformance: Boolean get() = route.highPerformance != null
    val isControlling: Boolean get() = phase == SessionPhase.Connected && controlAllowed
    val sendsGesturesToMac: Boolean get() = server?.gestures == true && isControlling

    /** The picture takes the window's shape (the virtual display on the direct path, the workspace's display). */
    val picturesFollowWindow: Boolean get() = route.followsWindowShape || usesHighPerformance && server?.virtualDisplay != false

    /** The resolution can be changed here (virtual display, the workspace's display from aOS). */
    val offersResolution: Boolean get() = picturesFollowWindow

    // Starting and ending

    fun start() {
        if (session == null && !isClosed) connect()
    }

    private fun connect() {
        teardown(keepPicture = true)
        generation++
        val gen = generation
        val factory = factory
        val remote = try {
            factory.create(
                RemoteSessionOptions(
                    host = route.host, port = route.port, username = route.username, password = route.password,
                    trustedFingerprint = trustedFingerprint, requireTrustedKey = usesHighPerformance,
                    allowUnverifiedLogin = allowUnverified, clientName = route.clientName.ifEmpty { route.username },
                    fullQuality = fullQuality, sharedClipboard = clipboardSharing, cacheDirectory = route.cacheDirectory,
                    decoderMaxPixelRate = if (usesHighPerformance) DecoderSupport.maximumPixelRate else 0,
                ),
                Listener(gen),
            )
        } catch (e: Exception) {
            phase = SessionPhase.Failed(SessionFailure(FailureKind.OTHER, e.message ?: ""))
            return
        }
        session = remote
        hasPicture = false
        if (usesHighPerformance) {
            decoder = VideoDecoder(
                onSize = { w, h -> post { if (gen == generation) pictureSize(w, h, video = true) } },
                requestKeyframe = { if (gen == generation) remote.requestKeyframe() },
                onFailure = { reason -> post { if (gen == generation) mediaFailed(MediaFailureKind.UNDECODABLE, reason) } },
            ).also { it.setSurface(videoSurface) }
            requestVirtualDisplay()
            remote.startHighPerformance(HighPerformanceRequest(DecoderSupport.codecs.ifEmpty { setOf(VideoCodec.H264) }))
        }
        if (phase !is SessionPhase.Reconnecting) phase = SessionPhase.Connecting
        remote.connect()
    }

    /** The person closed the session (or aOS did). Once. */
    fun close() {
        if (isClosed) return
        isClosed = true
        keyboard.releaseAll()
        releaseButtons()
        session?.disconnect()
        teardown(keepPicture = false)
        phase = SessionPhase.Disconnected
        onClosed?.invoke()
    }

    private fun teardown(keepPicture: Boolean) {
        reconnectToken++
        capturePicture()
        session?.abort()
        session = null
        generation++
        decoder?.release()
        decoder = null
        if (isVideo) {
            isVideo = false
            pictureSink?.videoChanged(false)
        }
        buttons = 0
        controlAllowed = true
        keyboard.secureInput = false
        if (!keepPicture) framebuffer = null
    }

    /** Try again after a failure (OSS's retry), also "Connect Anyway". */
    fun retry() {
        reconnectAttempts = 0
        isClosed = false
        connect()
    }

    fun trustKey(fingerprint: String) {
        trustedFingerprint = fingerprint
        onFingerprint?.invoke(fingerprint)
        retry()
    }

    fun allowUnverifiedLogin() {
        allowUnverified = true
        retry()
    }

    fun answerPrompt(choice: SessionChoice) {
        val prompt = (phase as? SessionPhase.ChoosingSession)?.prompt ?: return
        session?.answerPrompt(prompt.id, choice)
        phase = SessionPhase.Connecting
        if (choice == SessionChoice.CANCEL) close()
    }

    /** The renderer's video surface (null while it has none). */
    fun setVideoSurface(surface: VideoSurface?) {
        videoSurface = surface
        decoder?.setSurface(surface)
        if (surface != null && isVideo) session?.requestKeyframe()
    }

    /** The app comes back: a fresh picture (OSS asks for a keyframe or a refresh). */
    fun refresh() {
        if (phase != SessionPhase.Connected) return
        if (isVideo) session?.requestKeyframe() else session?.requestRefresh()
        sendChangedClipboard()
    }

    // The picture's area and resolution

    /** The area the picture is shown in changed (the view's size, turning the phone). */
    fun displayAreaChanged(area: ScreenArea, screenWidth: Int, screenHeight: Int) {
        if (area.width <= 0 || area.height <= 0) return
        val withResolution = area.copy(resolutionScale = resolutionScale)
        if (withResolution == this.area) return
        this.area = withResolution
        screenPixels = screenWidth to screenHeight
        requestVirtualDisplay()
        onDisplayArea?.invoke(withResolution)
    }

    fun changeResolutionScale(scale: Double) {
        if (scale == resolutionScale) return
        resolutionScale = scale
        area = area?.copy(resolutionScale = scale)
        requestVirtualDisplay()
        onResolutionScale?.invoke(scale)
        area?.let { if (route.followsWindowShape) onDisplayArea?.invoke(it) }
    }

    private fun requestVirtualDisplay() {
        val remote = session ?: return
        val area = area ?: return
        if (!usesHighPerformance || server?.virtualDisplay == false) return
        val mode = DisplayMode.matching(area.width, area.height, area.screenScale, resolutionScale) ?: return
        val (sw, sh) = screenPixels ?: (0 to 0)
        val largest = DisplayMode.largestSide(sw / area.screenScale, sh / area.screenScale, area.screenScale)
        remote.setVirtualDisplay(mode.alignedToWidthMultiple(remote.displayWidthMultiple), max(largest, max(mode.pixelWidth, mode.pixelHeight)))
    }

    // Pointer

    fun movePointer(x: Float, y: Float) {
        val (cx, cy) = clamp(x, y)
        pointerX = cx
        pointerY = cy
        pointerSink()
        if (isControlling) sendPointer()
    }

    fun movePointerBy(dx: Float, dy: Float) = movePointer(pointerX + dx, pointerY + dy)

    fun press(button: Int, count: Int? = null) {
        val now = uptimeMillis()
        val last = lastPress
        clickCount = when {
            count != null -> count
            last != null && last.first == button && now - last.third <= MULTI_CLICK_MILLIS &&
                hypot(pointerX - last.second.first, pointerY - last.second.second) <= MULTI_CLICK_DISTANCE -> clickCount + 1
            else -> 1
        }
        lastPress = Triple(button, pointerX to pointerY, now)
        if (!isControlling) return
        onForgetTypedText()
        if (buttons == 0) clickModifiers = keyboard.takeStickyForClick()
        buttons = buttons or button
        sendPointer()
    }

    fun release(button: Int) {
        if (buttons and button == 0) return
        buttons = buttons and button.inv()
        if (isControlling) sendPointer()
        if (buttons == 0 && clickModifiers.isNotEmpty()) {
            keyboard.releaseClickModifiers(clickModifiers)
            clickModifiers = emptySet()
        }
    }

    fun click(button: Int) {
        press(button)
        release(button)
    }

    /** Buttons as a mouse reports them (all at once). */
    fun setButtons(pressed: Int) {
        val released = buttons and pressed.inv()
        val down = pressed and buttons.inv()
        for (b in listOf(PointerButton.PRIMARY, PointerButton.MIDDLE, PointerButton.SECONDARY)) {
            if (released and b != 0) release(b)
            if (down and b != 0) press(b)
        }
    }

    private fun releaseButtons() {
        if (buttons != 0) {
            buttons = 0
            if (isControlling) sendPointer()
        }
    }

    private fun sendPointer() {
        session?.sendPointer(pointerX.toInt(), pointerY.toInt(), buttons, clickCount)
    }

    private fun clamp(x: Float, y: Float): Pair<Float, Float> {
        val w = imageWidth
        val h = imageHeight
        if (w <= 0 || h <= 0) return x to y
        return x.coerceIn(0f, (w - 1).toFloat()) to y.coerceIn(0f, (h - 1).toFloat())
    }

    private fun pointerSink() = pictureSink?.redraw()

    // Scrolling (deltas in picture pixels)

    fun scroll(dx: Float, dy: Float, phase: ScrollPhase?) {
        if (!isControlling) return
        val remote = session ?: return
        if (phase != null && sendsGesturesToMac) {
            gliding = false
            remote.sendScrollPhase(pointerX.toInt(), pointerY.toInt(), dx * pointsPerPixel, dy * pointsPerPixel,
                if (phase == ScrollPhase.BEGAN) GesturePhase.BEGAN else GesturePhase.CHANGED)
            return
        }
        scrollRemainderX += dx
        scrollRemainderY += dy
        val sendX = scrollRemainderX.toInt().toDouble()
        val sendY = scrollRemainderY.toInt().toDouble()
        if (sendX == 0.0 && sendY == 0.0) return
        scrollRemainderX -= sendX
        scrollRemainderY -= sendY
        remote.sendScroll(pointerX.toInt(), pointerY.toInt(), sendX * pointsPerPixel, sendY * pointsPerPixel)
    }

    fun scrollEnded(vx: Float, vy: Float, cancelled: Boolean) {
        scrollRemainderX = 0.0
        scrollRemainderY = 0.0
        if (!sendsGesturesToMac) return
        val remote = session ?: return
        remote.sendScrollPhase(pointerX.toInt(), pointerY.toInt(), 0.0, 0.0, if (cancelled) GesturePhase.CANCELLED else GesturePhase.ENDED)
        if (!cancelled && hypot(vx, vy) > 50) {
            gliding = true
            remote.startScrollMomentum(pointerX.toInt(), pointerY.toInt(), vx * pointsPerPixel, vy * pointsPerPixel)
        }
    }

    fun stopScrollMomentum() {
        if (!gliding) return
        gliding = false
        session?.stopScrollMomentum()
    }

    // Commands

    fun perform(command: SystemCommand) {
        if (!isControlling) return
        onForgetTypedText()
        val offered = when (command) {
            SystemCommand.MISSION_CONTROL -> server?.missionControl
            SystemCommand.APP_WINDOWS -> server?.appWindows
            SystemCommand.SHOW_DESKTOP -> server?.showDesktop
            SystemCommand.LAUNCHPAD -> server?.launchpad
        } == true
        if (offered) session?.sendSystemCommand(command) else command.fallback?.let { keyboard.sendChord(it) }
    }

    fun canPerform(command: SystemCommand): Boolean = when (command) {
        SystemCommand.LAUNCHPAD -> server?.launchpad == true
        else -> true
    }

    fun changeFullQuality(full: Boolean) {
        if (full == fullQuality) return
        fullQuality = full
        session?.setFullQuality(full)
        onFullQuality?.invoke(full)
    }

    // Clipboard

    fun changeClipboardSharing(enabled: Boolean) {
        if (enabled == clipboardSharing) return
        clipboardSharing = enabled
        session?.setSharedClipboard(enabled)
        onClipboardSharing?.invoke(enabled)
        if (enabled) sendChangedClipboard()
    }

    /** The phone's clipboard to the Mac when it changed (sync on: connecting, coming back, a copy here). */
    fun sendChangedClipboard() {
        if (!clipboardSharing || phase != SessionPhase.Connected || server?.clipboard == false) return
        val text = clipboard?.read() ?: return
        if (text == lastSentClipboard || text == lastRemoteClipboard) return
        lastSentClipboard = text
        session?.setClipboardText(text)
    }

    fun sendClipboardToMac() {
        val text = clipboard?.read() ?: return
        lastSentClipboard = text
        session?.setClipboardText(text)
    }

    fun receiveClipboardFromMac() {
        forceClipboard = true
        session?.requestClipboard()
    }

    private var forceClipboard = false

    // KeyOutput

    override fun sendKey(key: MacKey, down: Boolean) {
        session?.sendKey(key, down)
    }

    override fun sendText(text: String) {
        session?.sendText(text)
    }

    override fun pasteText(text: String) {
        session?.pasteText(text)
    }

    // The picture

    private fun pictureSize(width: Int, height: Int, video: Boolean) {
        if (video != isVideo) {
            isVideo = video
            pictureSink?.videoChanged(video)
        }
        if (width != imageWidth || height != imageHeight) {
            imageWidth = width
            imageHeight = height
            if (pointerX == 0f && pointerY == 0f || pointerX >= width || pointerY >= height) {
                pointerX = width / 2f
                pointerY = height / 2f
            }
        }
        hasPicture = true
    }

    /** The last picture as a JPEG (at most 1280 pixels wide) for the card, when the session lets go of it. */
    private fun capturePicture() {
        if (!hasPicture) return
        val sink = onPicture ?: return
        if (isVideo) {
            pictureSink?.captureVideo { bitmap -> bitmap?.let { sink(jpeg(it)) } }
            return
        }
        val fb = framebuffer ?: return
        val bitmap = framebufferBitmap(fb, 1280) ?: return
        sink(jpeg(bitmap))
    }

    // Failures

    private fun leavesDirectPath(kind: FailureKind) = when (kind) {
        FailureKind.AUTHENTICATION, FailureKind.CLOSED_BY_SERVER, FailureKind.ENDED, FailureKind.OWN_SCREEN,
        FailureKind.PERMISSION_DENIED -> false
        else -> true
    }

    /** aOS's direct path didn't work: the session ends and aOS goes through the SSH tunnel (once). */
    private fun leaveDirectPath(reason: String): Boolean {
        val handler = onDirectPathFailed ?: return false
        onDirectPathFailed = null
        keyboard.releaseAll()
        teardown(keepPicture = true)
        phase = SessionPhase.Disconnected
        handler(reason)
        return true
    }

    private fun mediaFailed(kind: MediaFailureKind, message: String) {
        if (!usesHighPerformance || isClosed) return
        if (leaveDirectPath("high performance failed (${kind.name.lowercase()}): $message")) return
        keyboard.releaseAll()
        teardown(keepPicture = true)
        phase = SessionPhase.Failed(SessionFailure(FailureKind.HIGH_PERFORMANCE, message, media = kind))
    }

    private fun handleState(state: RemoteState, failure: SessionFailure?) {
        val reconnecting = phase is SessionPhase.Reconnecting
        when (state) {
            RemoteState.CONNECTING -> if (!reconnecting) phase = SessionPhase.Connecting
            RemoteState.AUTHENTICATING -> if (!reconnecting) phase = SessionPhase.Authenticating
            RemoteState.WAITING_FOR_APPROVAL -> phase = SessionPhase.WaitingForPermission
            RemoteState.CHOOSING_SESSION -> Unit
            RemoteState.CONNECTED -> connected()
            RemoteState.DISCONNECTED -> disconnected(failure, reconnecting)
        }
    }

    private fun connected() {
        reconnectAttempts = 0
        phase = SessionPhase.Connected
        if (!hasConnected) {
            hasConnected = true
            onConnected?.invoke(model)
        }
        if (learnedFingerprint.isNotEmpty() && learnedFingerprint != trustedFingerprint) {
            trustedFingerprint = learnedFingerprint
            onFingerprint?.invoke(learnedFingerprint)
        }
        session?.setSharedClipboard(clipboardSharing)
        sendChangedClipboard()
        // aOS: a Mac without high performance (or its virtual display) on the direct path goes through the tunnel.
        val info = server
        if (usesHighPerformance && onDirectPathFailed != null && info != null && (!info.highPerformance || !info.virtualDisplay)) {
            leaveDirectPath("the Mac offers no high performance")
            return
        }
        requestVirtualDisplay()
    }

    private fun disconnected(failure: SessionFailure?, reconnecting: Boolean) {
        if (isClosed) return
        keyboard.releaseAll()
        if (failure == null) {
            teardown(keepPicture = true)
            phase = SessionPhase.Disconnected
            return
        }
        // aOS: a login from aOS that the screen refused goes back to aOS, which asks for another.
        if (failure.kind == FailureKind.AUTHENTICATION) {
            onLoginRefused?.let {
                teardown(keepPicture = true)
                it()
                return
            }
        }
        if (leavesDirectPath(failure.kind) && leaveDirectPath(failure.message.ifEmpty { failure.kind.name.lowercase() })) return
        val unreachable = failure.kind == FailureKind.UNREACHABLE || failure.kind == FailureKind.HOST_NOT_FOUND
        val retryable = failure.kind == FailureKind.CONNECTION_LOST || reconnecting && unreachable
        if (retryable && hasConnected && reconnectAttempts < RECONNECT_LIMIT) {
            reconnectAttempts++
            val attempt = reconnectAttempts
            teardown(keepPicture = true)
            phase = SessionPhase.Reconnecting(attempt)
            val token = reconnectToken
            val delay = min(1L shl (attempt - 1), 8L) * 1000
            Thread {
                Thread.sleep(delay)
                post { if (token == reconnectToken && phase is SessionPhase.Reconnecting && !isClosed) connect() }
            }.apply { isDaemon = true }.start()
            return
        }
        teardown(keepPicture = true)
        phase = SessionPhase.Failed(if (reconnecting && unreachable) failure.copy(kind = FailureKind.CONNECTION_LOST) else failure)
    }

    /** libsharing's reports for one connection; those of an older one are dropped. */
    private inner class Listener(private val gen: Int) : RemoteSessionListener {
        private fun onMain(block: () -> Unit) = post { if (gen == generation) block() }

        override fun onState(state: RemoteState, failure: SessionFailure?) = onMain { handleState(state, failure) }
        override fun onServerInfo(info: ServerInfoData) = onMain {
            server = info
            controlAllowed = !info.observeOnly
        }

        override fun onFingerprint(fingerprint: String) = onMain { learnedFingerprint = fingerprint }

        override fun onFramebuffer(framebuffer: Framebuffer) {
            if (gen != generation) return
            this@SessionModel.framebuffer = framebuffer
            pictureSink?.framebufferChanged(framebuffer)
            onMain { pictureSize(framebuffer.width, framebuffer.height, video = false) }
        }

        override fun onFramebufferUpdate(x: Int, y: Int, width: Int, height: Int) {
            if (gen != generation) return
            pictureSink?.framebufferDirty(x, y, width, height)
        }

        override fun onCursor(cursor: CursorData?) {
            if (gen != generation) return
            this@SessionModel.cursor = cursor
            pictureSink?.cursorChanged()
        }

        override fun onCursorPosition(x: Int, y: Int) = onMain {
            if (buttons == 0) {
                pointerX = x.toFloat()
                pointerY = y.toFloat()
                pointerSink()
            }
        }

        override fun onVideoFormat(format: VideoFormatInfo) {
            if (gen != generation) return
            decoder?.format(format)
            onMain {
                if (!isVideo) {
                    isVideo = true
                    pictureSink?.videoChanged(true)
                }
            }
        }

        override fun onVideoUnit(unit: VideoUnit) {
            if (gen != generation) return
            decoder?.unit(unit)
        }

        override fun onMediaStopped(failure: MediaFailureKind?, message: String) = onMain {
            if (failure == null) {
                if (isVideo) {
                    isVideo = false
                    pictureSink?.videoChanged(false)
                }
            } else {
                mediaFailed(failure, message)
            }
        }

        override fun onClipboardText(text: String) = onMain {
            if (!clipboardSharing && !forceClipboard) return@onMain
            forceClipboard = false
            lastRemoteClipboard = text
            clipboard?.write(text)
        }

        override fun onKeyboardSource(id: String, secureInput: Boolean) = onMain {
            keyboard.secureInput = secureInput
            keyboard.macComposes = MAC_INPUT_METHODS.any { id.startsWith(it) }
        }

        override fun onPointerVisible(visible: Boolean) {
            pointerVisible = visible
            pictureSink?.redraw()
        }

        override fun onControlAllowed(allowed: Boolean) = onMain {
            controlAllowed = allowed
            if (!allowed) keyboard.releaseAll()
        }

        override fun onPrompt(prompt: SessionPrompt) = onMain { phase = SessionPhase.ChoosingSession(prompt) }
        override fun onDeviceInfo(model: String, color: String) = onMain { this@SessionModel.model = model }
        override fun onPointsPerPixel(ratio: Double) = onMain { pointsPerPixel = ratio }
    }

    companion object {
        const val RECONNECT_LIMIT = 6
        const val MULTI_CLICK_MILLIS = 500L
        const val MULTI_CLICK_DISTANCE = 4f

        /** macOS keyboard sources that compose text (input methods): text is pasted to them. */
        private val MAC_INPUT_METHODS = listOf("com.apple.inputmethod.", "com.google.inputmethod.")

        /** The framebuffer (B, G, R, X) as a bitmap, at most `maxWidth` wide. */
        /** The framebuffer as a picture (the card's), at most `maxWidth` wide (ScreenImages: the platform's own). */
        fun framebufferBitmap(fb: Framebuffer, maxWidth: Int): PlatformBitmap? = ScreenImages.framebufferBitmap(fb, maxWidth)

        fun jpeg(bitmap: PlatformBitmap): ByteArray = ScreenImages.jpeg(bitmap)
    }
}
