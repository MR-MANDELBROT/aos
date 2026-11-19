package dev.marquart.aos.desktop

import dev.marquart.aos.screen.DemoScreenServer
import dev.marquart.aos.screen.Keysym
import dev.marquart.aos.screen.MacKey
import dev.marquart.aos.screen.PointerButton
import dev.marquart.aos.screen.SessionModel
import dev.marquart.aos.screen.SessionPhase
import dev.marquart.aos.screen.SessionRoute
import dev.marquart.aos.waitUntil
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The shared SessionModel with libsharing through the desktop Go library (JNA), against the demo's RFB server: the
 * picture arrives, clicks and keys reach the server. Runs where the library for this system is built
 * (third_party/aosgo-desktop/out/darwin-arm64 on this Mac; desktop/build.gradle.kts passes its path).
 */
class GoScreenTests {
    @Test fun aSessionThroughTheGoLibrary() = runBlocking {
        assumeTrue("the Go library isn't built for this system", GoLibrary.AVAILABLE)
        val server = DemoScreenServer.start(640, 400, "Test")
        val model = SessionModel(SessionRoute("test", "Test", "127.0.0.1", server.port, "", null, followsWindowShape = false),
            GoLibrary.screenSessions, { it.run() })
        try {
            model.start()
            waitUntil(15_000, "connected") { model.phase == SessionPhase.Connected && model.hasPicture }
            assertEquals(640, model.imageWidth)
            val fb = model.framebuffer!!
            // The demo's gradient starts dark blue (0x1d, 0x3b, 0x6e) in the top left (BGRX in memory, under the menu bar).
            val at = 40 * fb.bytesPerRow + 4 * 4
            assertTrue((fb.pixels.get(at + 2).toInt() and 0xff) < 0x80, "red is low in the dark blue corner")
            model.movePointer(100f, 200f)
            model.press(PointerButton.PRIMARY)
            model.release(PointerButton.PRIMARY)
            waitUntil(5_000, "click") { server.pointerEvents.any { it.first == 100 && it.second == 200 && it.third and 1 != 0 } }
            model.keyboard.typeKey(MacKey(0, 'a'.code))
            waitUntil(5_000, "key") { 'a'.code in server.keysDown || Keysym.character('a'.code) in server.keysDown }
        } finally {
            model.close()
            server.stop()
        }
    }
}
