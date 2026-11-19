package dev.marquart.aos.screen

import org.junit.Test
import java.nio.ByteBuffer
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A session's phases, failures, the direct path's hand-over and the pointer, against a session engine in memory. */
class SessionModelTests {
    private class FakeSession(val options: RemoteSessionOptions, val listener: RemoteSessionListener) : RemoteSession {
        val calls = ArrayList<String>()
        override fun connect() { calls += "connect" }
        override fun disconnect() { calls += "disconnect" }
        override fun abort() { calls += "abort" }
        override fun sendPointer(x: Int, y: Int, buttons: Int, clickCount: Int) { calls += "pointer $x,$y $buttons $clickCount" }
        override fun sendScroll(x: Int, y: Int, dx: Double, dy: Double) { calls += "scroll $dx,$dy" }
        override fun sendScrollPhase(x: Int, y: Int, dx: Double, dy: Double, phase: GesturePhase) { calls += "scrollPhase $phase" }
        override fun startScrollMomentum(x: Int, y: Int, vx: Double, vy: Double) { calls += "momentum" }
        override fun stopScrollMomentum() {}
        override fun sendKey(key: MacKey, down: Boolean) { calls += "key ${key.keysym} $down" }
        override fun sendText(text: String) { calls += "text $text" }
        override fun pasteText(text: String) { calls += "paste $text" }
        override fun sendSystemCommand(command: SystemCommand) { calls += "system $command" }
        override fun setClipboardText(text: String) { calls += "clipboard $text" }
        override fun requestClipboard() { calls += "requestClipboard" }
        override fun setSharedClipboard(enabled: Boolean) { calls += "sharedClipboard $enabled" }
        override fun setVirtualDisplay(mode: DisplayMode, largestSide: Int) { calls += "virtualDisplay ${mode.pixelWidth}x${mode.pixelHeight}" }
        override fun startHighPerformance(request: HighPerformanceRequest) { calls += "highPerformance bands=${request.bands} coreDevice=${request.coreDevice} audio=${request.audio}" }
        override fun requestKeyframe() { calls += "keyframe" }
        override fun requestRefresh() { calls += "refresh" }
        override fun setFullQuality(full: Boolean) { calls += "quality $full" }
        override fun setVisible(visible: Boolean) {}
        override fun answerPrompt(id: Long, choice: SessionChoice) { calls += "answer $choice" }
        override val displayWidthMultiple = 1
    }

    private class Factory : RemoteSessionFactory {
        val sessions = ArrayList<FakeSession>()
        override val available = true
        override fun create(options: RemoteSessionOptions, listener: RemoteSessionListener) = FakeSession(options, listener).also { sessions += it }
        override fun checkLogin(options: RemoteSessionOptions) = LoginCheckResult.Failed("not here")
        val last get() = sessions.last()
    }

    private fun info(highPerformance: Boolean = false, virtualDisplay: Boolean = false, gestures: Boolean = false) = ServerInfoData(
        1280, 800, apple = true, observeOnly = false, virtualDisplay = virtualDisplay, highPerformance = highPerformance,
        clipboard = true, clipboardRequest = true, keyboardSource = true, keyCodes = true, gestures = gestures,
        missionControl = true, appWindows = false, showDesktop = true, launchpad = false, quality = true, unicodeText = true,
    )

    private fun route(highPerformance: ScreenNetwork? = null) = SessionRoute(
        screenId = "S", name = "Mac", host = "127.0.0.1", port = 5901, username = "max", password = "secret",
        followsWindowShape = false, highPerformance = highPerformance, trustedFingerprint = "SHA256:old",
    )

    private fun connected(model: SessionModel, factory: Factory, info: ServerInfoData = info()) {
        val l = factory.last.listener
        l.onServerInfo(info)
        l.onFramebuffer(Framebuffer(ByteBuffer.allocateDirect(1280 * 800 * 4), 1280, 800, 1280 * 4))
        l.onState(RemoteState.CONNECTED, null)
    }

    @Test fun aSessionConnectsWithItsLoginAndTheKeyItTrusts() {
        val factory = Factory()
        val model = SessionModel(route(), factory, { it.run() })
        model.start()
        val options = factory.last.options
        assertEquals("127.0.0.1", options.host)
        assertEquals(5901, options.port)
        assertEquals("secret", options.password)
        assertEquals("SHA256:old", options.trustedFingerprint)
        assertFalse(options.requireTrustedKey)
        assertEquals(listOf("connect"), factory.last.calls)
        assertEquals(SessionPhase.Connecting, model.phase)

        var learned: String? = null
        var connectedOnce = 0
        model.onFingerprint = { learned = it }
        model.onConnected = { connectedOnce++ }
        factory.last.listener.onFingerprint("SHA256:new")
        connected(model, factory)
        assertEquals(SessionPhase.Connected, model.phase)
        assertTrue(model.hasPicture)
        assertEquals(1280, model.imageWidth)
        assertEquals("SHA256:new", learned)
        assertEquals(1, connectedOnce)
        assertTrue("sharedClipboard true" in factory.last.calls)
    }

    @Test fun aRefusedLoginGoesBackToAOS() {
        val factory = Factory()
        val model = SessionModel(route(), factory, { it.run() })
        var refused = 0
        model.onLoginRefused = { refused++ }
        model.start()
        factory.last.listener.onState(RemoteState.DISCONNECTED, SessionFailure(FailureKind.AUTHENTICATION, "nope"))
        assertEquals(1, refused)
        assertIs<SessionPhase.Connecting>(model.phase)
    }

    @Test fun theDirectPathSignsInOnlyWithTheKnownKeyAndHandsOverWhenItFails() {
        val factory = Factory()
        val model = SessionModel(route(ScreenNetwork.INTERNET), factory, { it.run() })
        var failed: String? = null
        model.onDirectPathFailed = { failed = it }
        model.displayAreaChanged(ScreenArea(400.0, 800.0, 2.625, 1.0), 1080, 2340)
        model.start()
        val session = factory.last
        assertTrue(session.options.requireTrustedKey)
        // The virtual display and high performance are asked for before connecting (libsharing keeps them)
        assertEquals(listOf("virtualDisplay 1050x2100", "highPerformance bands=1 coreDevice=true audio=false", "connect"), session.calls)
        session.listener.onState(RemoteState.DISCONNECTED, SessionFailure(FailureKind.UNREACHABLE, "no route"))
        assertEquals("no route", failed)
        assertEquals(SessionPhase.Disconnected, model.phase)
    }

    @Test fun aMacWithoutHighPerformanceLeavesTheDirectPath() {
        val factory = Factory()
        val model = SessionModel(route(ScreenNetwork.LOCAL_NETWORK), factory, { it.run() })
        var failed: String? = null
        model.onDirectPathFailed = { failed = it }
        model.start()
        connected(model, factory, info(highPerformance = false, virtualDisplay = true))
        assertEquals("the Mac offers no high performance", failed)
    }

    @Test fun highPerformanceStoppingWithAnErrorHandsOverToo() {
        val factory = Factory()
        val model = SessionModel(route(ScreenNetwork.LOCAL_NETWORK), factory, { it.run() })
        var failed: String? = null
        model.onDirectPathFailed = { failed = it }
        model.start()
        connected(model, factory, info(highPerformance = true, virtualDisplay = true))
        assertNull(failed)
        factory.last.listener.onMediaStopped(MediaFailureKind.SILENT, "no packets")
        assertEquals("high performance failed (silent): no packets", failed)
    }

    @Test fun aLostConnectionReconnects() {
        val factory = Factory()
        val model = SessionModel(route(), factory, { it.run() })
        model.start()
        connected(model, factory)
        factory.last.listener.onState(RemoteState.DISCONNECTED, SessionFailure(FailureKind.CONNECTION_LOST, "reset"))
        assertEquals(SessionPhase.Reconnecting(1), model.phase)
        assertTrue(model.hasPicture, "the last picture stays while reconnecting")
    }

    @Test fun reportsOfAnOlderConnectionAreDropped() {
        val factory = Factory()
        val model = SessionModel(route(), factory, { it.run() })
        model.start()
        val old = factory.last
        model.retry()
        old.listener.onState(RemoteState.CONNECTED, null)
        assertEquals(SessionPhase.Connecting, model.phase)
    }

    @Test fun clicksAndDoubleClicksGoToThePointer() {
        val factory = Factory()
        val model = SessionModel(route(), factory, { it.run() })
        model.start()
        connected(model, factory)
        factory.last.calls.clear()
        model.movePointer(100f, 50f)
        model.click(PointerButton.PRIMARY)
        model.click(PointerButton.PRIMARY)
        model.movePointer(5000f, -10f)
        assertEquals(
            listOf("pointer 100,50 0 1", "pointer 100,50 1 1", "pointer 100,50 0 1", "pointer 100,50 1 2", "pointer 100,50 0 2", "pointer 1279,0 0 2"),
            factory.last.calls,
        )
    }

    @Test fun aTappedModifierGoesDownWithTheNextClick() {
        val factory = Factory()
        val model = SessionModel(route(), factory, { it.run() })
        model.start()
        connected(model, factory)
        factory.last.calls.clear()
        model.keyboard.toggleSticky(ModifierKey.COMMAND)
        model.click(PointerButton.PRIMARY)
        assertEquals(listOf("key ${Keysym.COMMAND_LEFT} true", "pointer 640,400 1 1", "pointer 640,400 0 1", "key ${Keysym.COMMAND_LEFT} false"), factory.last.calls)
    }

    @Test fun scrollingSendsWholePixelsOrPhases() {
        val factory = Factory()
        val model = SessionModel(route(), factory, { it.run() })
        model.start()
        connected(model, factory)
        factory.last.calls.clear()
        model.scroll(0f, 0.6f, ScrollPhase.BEGAN)
        model.scroll(0f, 0.6f, ScrollPhase.CHANGED)
        assertEquals(listOf("scroll 0.0,0.5"), factory.last.calls)

        val gestures = Factory()
        val withGestures = SessionModel(route(), gestures, { it.run() })
        withGestures.start()
        connected(withGestures, gestures, info(gestures = true))
        gestures.last.calls.clear()
        withGestures.scroll(0f, 3f, ScrollPhase.BEGAN)
        withGestures.scrollEnded(0f, 400f, cancelled = false)
        assertEquals(listOf("scrollPhase BEGAN", "scrollPhase ENDED", "momentum"), gestures.last.calls)
    }

    @Test fun systemCommandsUseTheirShortcutWhereTheMacOffersNone() {
        val factory = Factory()
        val model = SessionModel(route(), factory, { it.run() })
        model.start()
        connected(model, factory)
        factory.last.calls.clear()
        model.perform(SystemCommand.MISSION_CONTROL)
        model.perform(SystemCommand.APP_WINDOWS)
        assertEquals(
            listOf("system MISSION_CONTROL", "key ${Keysym.CONTROL_LEFT} true", "key ${Keysym.DOWN} true", "key ${Keysym.DOWN} false", "key ${Keysym.CONTROL_LEFT} false"),
            factory.last.calls,
        )
    }

    @Test fun theClipboardSyncsBothWaysWithoutEchoes() {
        val factory = Factory()
        val model = SessionModel(route(), factory, { it.run() })
        var phone: String? = "from the phone"
        model.clipboard = object : ClipboardBridge {
            override fun read() = phone
            override fun write(text: String) { phone = text }
        }
        model.start()
        connected(model, factory)
        assertTrue("clipboard from the phone" in factory.last.calls)
        factory.last.listener.onClipboardText("from the Mac")
        assertEquals("from the Mac", phone)
        factory.last.calls.clear()
        model.sendChangedClipboard()
        assertTrue(factory.last.calls.isEmpty(), "what came from the Mac doesn't go back")
        model.changeClipboardSharing(false)
        factory.last.listener.onClipboardText("not synced")
        assertEquals("from the Mac", phone)
    }

    @Test fun closingLetsGoOfEverything() {
        val factory = Factory()
        val model = SessionModel(route(), factory, { it.run() })
        var closed = 0
        model.onClosed = { closed++ }
        model.start()
        connected(model, factory)
        model.press(PointerButton.PRIMARY)
        model.close()
        model.close()
        assertEquals(1, closed)
        assertTrue(model.isClosed)
        assertTrue(factory.last.calls.containsAll(listOf("disconnect", "abort")))
        assertNull(model.framebuffer)
    }
}
