package dev.marquart.aos.screen

import org.junit.Test
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Fingers made into pointer actions (OSS's ScreenInput) and where the picture sits (its RemoteScreenView). */
class GestureTests {
    private class Sink(override var isControlling: Boolean = true) : TouchGestures.Sink {
        val events = ArrayList<String>()
        var moved = 0f to 0f
        var zoomFactor = 1f
        override fun movePointerBy(dx: Float, dy: Float, speed: Float) {
            moved = moved.first + dx to moved.second + dy
            events += "by"
        }
        override fun movePointerTo(x: Float, y: Float) { events += "to ${x.toInt()},${y.toInt()}" }
        override fun press(button: Int) { events += "press $button" }
        override fun release(button: Int) { events += "release $button" }
        override fun click(button: Int) { events += "click $button" }
        override fun scroll(dx: Float, dy: Float, phase: ScrollPhase) { events += "scroll ${dy.toInt()} $phase" }
        override fun scrollEnded(velocityX: Float, velocityY: Float, cancelled: Boolean) { events += "scrollEnded $cancelled" }
        override fun zoom(factor: Float, fromX: Float, fromY: Float, toX: Float, toY: Float) {
            zoomFactor *= factor
            events += "zoom"
        }
    }

    @Test fun aTapClicksWhereThePointerIs() {
        val sink = Sink()
        val g = TouchGestures(sink, density = 1f)
        g.down(0, 100f, 100f, 0)
        g.move(mapOf(0 to (103f to 102f)), 50)
        g.up(0, 103f, 102f, 120)
        assertEquals(listOf("click 1"), sink.events)
    }

    @Test fun aSlowTapIsNoClick() {
        val sink = Sink()
        val g = TouchGestures(sink, density = 1f)
        g.down(0, 100f, 100f, 0)
        g.up(0, 100f, 100f, 400)
        assertTrue(sink.events.isEmpty())
    }

    @Test fun movingAFingerMovesThePointerWithoutTheTapSlop() {
        val sink = Sink()
        val g = TouchGestures(sink, density = 2f)
        g.down(0, 100f, 100f, 0)
        g.move(mapOf(0 to (110f to 100f)), 16) // within the 20 px slop at density 2: nothing yet
        assertTrue(sink.events.isEmpty())
        g.move(mapOf(0 to (130f to 100f)), 32) // beyond: everything since the finger went down
        g.move(mapOf(0 to (140f to 110f)), 48)
        g.up(0, 140f, 110f, 64)
        assertEquals(listOf("by", "by"), sink.events)
        assertEquals(40f to 10f, sink.moved)
    }

    @Test fun holdingDragsUntilTheFingerLifts() {
        val sink = Sink()
        val g = TouchGestures(sink, density = 1f)
        g.down(0, 100f, 100f, 1000)
        g.hold(1000)
        g.move(mapOf(0 to (150f to 100f)), 1400)
        g.up(0, 150f, 100f, 1500)
        assertEquals(listOf("press 1", "by", "release 1"), sink.events)
    }

    @Test fun anOldHoldTimerDoesNothing() {
        val sink = Sink()
        val g = TouchGestures(sink, density = 1f)
        g.down(0, 100f, 100f, 1000)
        g.up(0, 100f, 100f, 1100)
        g.down(0, 100f, 100f, 2000)
        g.hold(1000)
        assertEquals(listOf("click 1"), sink.events)
    }

    @Test fun twoFingersTappedAreARightClick() {
        val sink = Sink()
        val g = TouchGestures(sink, density = 1f)
        g.down(0, 100f, 100f, 0)
        g.down(1, 200f, 100f, 20)
        g.up(0, 100f, 100f, 150)
        g.up(1, 200f, 100f, 160)
        assertEquals(listOf("click 4"), sink.events)
    }

    @Test fun twoFingersMovingTogetherScroll() {
        val sink = Sink()
        val g = TouchGestures(sink, density = 1f)
        g.down(0, 100f, 100f, 0)
        g.down(1, 200f, 100f, 10)
        g.move(mapOf(0 to (100f to 120f), 1 to (200f to 120f)), 30)
        g.move(mapOf(0 to (100f to 150f), 1 to (200f to 150f)), 50)
        g.up(0, 100f, 150f, 60)
        g.up(1, 200f, 150f, 60)
        assertEquals(listOf("scroll 20 BEGAN", "scroll 30 CHANGED", "scrollEnded false"), sink.events)
    }

    @Test fun twoFingersSpreadingZoom() {
        val sink = Sink()
        val g = TouchGestures(sink, density = 1f)
        g.down(0, 100f, 100f, 0)
        g.down(1, 200f, 100f, 10)
        g.move(mapOf(0 to (50f to 100f), 1 to (250f to 100f)), 30)
        g.up(0, 50f, 100f, 400)
        g.up(1, 250f, 100f, 400)
        assertEquals(listOf("zoom"), sink.events)
        assertTrue(abs(sink.zoomFactor - 2f) < 0.01f)
    }

    @Test fun directTouchClicksWhereTheFingerIs() {
        val sink = Sink()
        val g = TouchGestures(sink, density = 1f, mode = TouchMode.DIRECT)
        g.down(0, 300f, 200f, 0)
        g.up(0, 301f, 200f, 100)
        assertEquals(listOf("to 300,200", "click 1"), sink.events)
    }

    @Test fun directTouchDragsWithTheFinger() {
        val sink = Sink()
        val g = TouchGestures(sink, density = 1f, mode = TouchMode.DIRECT)
        g.down(0, 300f, 200f, 0)
        g.move(mapOf(0 to (330f to 200f)), 50)
        g.up(0, 360f, 200f, 100)
        assertEquals(listOf("to 300,200", "press 1", "to 330,200", "to 360,200", "release 1"), sink.events)
    }

    @Test fun watchingOnlyNoClicks() {
        val sink = Sink(isControlling = false)
        val g = TouchGestures(sink, density = 1f)
        g.down(0, 100f, 100f, 0)
        g.hold(0)
        g.up(0, 100f, 100f, 100)
        assertTrue(sink.events.isEmpty())
    }

    @Test fun fasterFingersMoveThePointerFurther() {
        assertEquals(1.2f, TouchGestures.pointerGain(0f))
        assertEquals(3.0f, TouchGestures.pointerGain(10_000f))
    }

    // The picture's place

    @Test fun thePictureFitsAndCenters() {
        val v = Viewport()
        v.layout(1000f, 1000f, 2000f, 1000f)
        assertEquals(0.5f, v.scale)
        assertEquals(0f, v.drawX)
        assertEquals(250f, v.drawY)
        assertEquals(1000f, v.imagePointX(500f))
        assertEquals(500f, v.imagePointY(500f))
    }

    @Test fun zoomingKeepsThePointUnderTheFingers() {
        val v = Viewport()
        v.layout(1000f, 500f, 2000f, 1000f)
        v.setZoom(2f, 1500f, 500f, 750f, 250f)
        assertEquals(1f, v.scale)
        assertEquals(1500f, v.imagePointX(750f))
        assertEquals(500f, v.imagePointY(250f))
        // The picture's edges stay at the view's edges
        v.pan(10_000f, 0f)
        assertEquals(0f, v.drawX)
        v.fit()
        assertEquals(0.5f, v.scale)
    }

    @Test fun thePictureLiftsAboveTheKeyboard() {
        val v = Viewport()
        v.layout(400f, 800f, 400f, 800f)
        // The pointer at 700, the keyboard from 500: lifted so the pointer is 48 above it
        v.liftAbove(500f, 700f, 48f)
        assertEquals(248f, v.lift)
        assertEquals(700f - 248f, v.viewPointY(700f))
        // Not further than the picture's bottom at the keyboard
        v.liftAbove(500f, 790f, 48f)
        assertEquals(300f, v.lift)
        v.liftAbove(null, 790f, 48f)
        assertEquals(0f, v.lift)
    }

    @Test fun thePointerStaysInAZoomedPicture() {
        val v = Viewport()
        v.layout(1000f, 500f, 2000f, 1000f)
        v.setZoom(2f, 0f, 0f, 0f, 0f)
        v.keepVisible(1900f, 900f, 20f)
        assertTrue(v.viewPointX(1900f) <= 980f)
        assertTrue(v.viewPointY(900f) <= 480f)
    }
}
