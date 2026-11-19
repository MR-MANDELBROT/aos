// Based on Open Screen Sharing by nekohasekai (GPL-3.0); Android/app/src/main/assets/open-screen-sharing/LICENSE,
// COPYING. Ported for aOS's Android app on 2026-11-19 from iOS/ThirdParty/OpenScreenSharing (SessionUI/ScreenInput.swift:
// the finger as a trackpad, taps, holding to drag, two-finger scrolling and taps, pinching; RemoteScreenView.swift:
// zoom and pan). UIKit's gesture recognizers become one state machine fed with Android's touch events.

package dev.marquart.aos.screen

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** How fingers control the Mac's pointer. */
enum class TouchMode(val raw: String) {
    /** The screen is a trackpad (OSS): a finger moves the pointer, a tap clicks where the pointer is, holding drags. */
    TRACKPAD("trackpad"),

    /** The finger is the pointer: a tap clicks where it lands, moving the finger drags. */
    DIRECT("direct");

    companion object {
        fun from(raw: String?): TouchMode = entries.firstOrNull { it.raw == raw } ?: TRACKPAD
    }
}

enum class ScrollPhase { BEGAN, CHANGED }

/** Pointer buttons as libsharing counts them. */
object PointerButton {
    const val PRIMARY = 1
    const val MIDDLE = 2
    const val SECONDARY = 4
}

/**
 * Touches on the picture, made into pointer actions: OSS's ScreenInput for fingers. Positions are view pixels, times
 * milliseconds. The view calls `hold` when `holdDelayMillis` have passed after a finger went down (a posted runnable).
 */
class TouchGestures(private val sink: Sink, density: Float, var mode: TouchMode = TouchMode.TRACKPAD) {
    interface Sink {
        val isControlling: Boolean
        /** Trackpad: moves the pointer by a finger's movement (view pixels) at a speed (pixels per second). */
        fun movePointerBy(dx: Float, dy: Float, speed: Float)
        /** Direct: the pointer goes where the finger is. */
        fun movePointerTo(x: Float, y: Float)
        fun press(button: Int)
        fun release(button: Int)
        fun click(button: Int)
        fun scroll(dx: Float, dy: Float, phase: ScrollPhase)
        fun scrollEnded(velocityX: Float, velocityY: Float, cancelled: Boolean)
        /** Zooms the picture by `factor` keeping what was under `from` under `to` (view pixels). */
        fun zoom(factor: Float, fromX: Float, fromY: Float, toX: Float, toY: Float)
        fun holdStarted() {}
    }

    val tapSlop = 10f * density
    private val pinchSlop = 24f * density

    private enum class Phase { PENDING, POINTING, DRAGGING }

    private class Finger(val id: Int, val startX: Float, val startY: Float, val startTime: Long) {
        var lastX = startX
        var lastY = startY
        var phase = Phase.PENDING
        var travel = 0f
        var pendingDx = 0f
        var pendingDy = 0f
        val samples = ArrayDeque<Triple<Float, Float, Long>>()

        fun record(x: Float, y: Float, t: Long) {
            travel = max(travel, hypot(x - startX, y - startY))
            lastX = x
            lastY = y
            samples.addLast(Triple(x, y, t))
            while (samples.isNotEmpty() && t - samples.first().third > 100) samples.removeFirst()
        }
    }

    private enum class TwoKind { UNDECIDED, SCROLL, PINCH }

    private class Two(val startTime: Long, var cx: Float, var cy: Float, var spread: Float) {
        val startCx = cx
        val startCy = cy
        val startSpread = spread
        var kind = TwoKind.UNDECIDED
        var scrolled = false
        val samples = ArrayDeque<Triple<Float, Float, Long>>()
    }

    private val points = LinkedHashMap<Int, Pair<Float, Float>>()
    private var finger: Finger? = null
    private var two: Two? = null

    /** Fingers that no longer count until all are lifted (a third finger, the rest of a two-finger tap). */
    private var consumed = false

    val holdDelayMillis = HOLD_MILLIS

    fun down(id: Int, x: Float, y: Float, time: Long) {
        points[id] = x to y
        if (consumed) return
        when (points.size) {
            1 -> finger = Finger(id, x, y, time)
            2 -> {
                finger?.let { end(it, null) }
                finger = null
                val (cx, cy) = centroid()
                two = Two(time, cx, cy, spread(cx, cy))
            }
            else -> {
                two?.let { endTwo(it, cancelled = true) }
                two = null
                consumed = true
            }
        }
    }

    /** Fingers moved (`moved`: every finger's position now). */
    fun move(moved: Map<Int, Pair<Float, Float>>, time: Long) {
        for ((id, p) in moved) if (id in points) points[id] = p
        if (consumed) return
        finger?.let { f ->
            val (x, y) = points[f.id] ?: return
            moveFinger(f, x, y, time)
            return
        }
        two?.let { moveTwo(it, time) }
    }

    fun up(id: Int, x: Float, y: Float, time: Long) {
        if (id in points) points[id] = x to y
        if (!consumed) {
            finger?.takeIf { it.id == id }?.let {
                if (x != it.lastX || y != it.lastY) moveFinger(it, x, y, time)
                end(it, time)
                finger = null
            }
            two?.let { t ->
                endTwo(t, cancelled = false, time = time)
                two = null
                consumed = true
            }
        }
        points.remove(id)
        if (points.isEmpty()) consumed = false
    }

    /** The system took the touches (a system gesture, the view went away). */
    fun cancel() {
        finger?.let { end(it, null) }
        finger = null
        two?.let { endTwo(it, cancelled = true) }
        two = null
        points.clear()
        consumed = false
    }

    /** The hold timer of the finger that went down at `downTime` ran out. */
    fun hold(downTime: Long) {
        val f = finger ?: return
        if (f.phase != Phase.PENDING || f.startTime != downTime || !sink.isControlling) return
        f.phase = Phase.DRAGGING
        if (mode == TouchMode.DIRECT) sink.movePointerTo(f.startX, f.startY)
        sink.press(PointerButton.PRIMARY)
        sink.holdStarted()
    }

    private fun moveFinger(f: Finger, x: Float, y: Float, time: Long) {
        val dx = x - f.lastX
        val dy = y - f.lastY
        f.record(x, y, time)
        when (mode) {
            TouchMode.TRACKPAD -> {
                if (f.phase == Phase.PENDING) {
                    f.pendingDx += dx
                    f.pendingDy += dy
                    if (f.travel <= tapSlop) return
                    f.phase = Phase.POINTING
                    sink.movePointerBy(f.pendingDx, f.pendingDy, speed(f.samples))
                    return
                }
                sink.movePointerBy(dx, dy, speed(f.samples))
            }
            TouchMode.DIRECT -> {
                if (f.phase == Phase.PENDING) {
                    if (f.travel <= tapSlop || !sink.isControlling) return
                    f.phase = Phase.DRAGGING
                    sink.movePointerTo(f.startX, f.startY)
                    sink.press(PointerButton.PRIMARY)
                }
                sink.movePointerTo(x, y)
            }
        }
    }

    private fun end(f: Finger, time: Long?) {
        when (f.phase) {
            Phase.PENDING -> {
                if (time == null || f.travel > tapSlop || time - f.startTime > TAP_MILLIS || !sink.isControlling) return
                if (mode == TouchMode.DIRECT) sink.movePointerTo(f.startX, f.startY)
                sink.click(PointerButton.PRIMARY)
            }
            Phase.POINTING -> Unit
            Phase.DRAGGING -> sink.release(PointerButton.PRIMARY)
        }
    }

    private fun moveTwo(t: Two, time: Long) {
        val (cx, cy) = centroid()
        val spread = spread(cx, cy)
        if (t.kind == TwoKind.UNDECIDED) {
            t.kind = when {
                abs(spread - t.startSpread) > pinchSlop -> TwoKind.PINCH
                hypot(cx - t.startCx, cy - t.startCy) > tapSlop -> if (sink.isControlling) TwoKind.SCROLL else TwoKind.PINCH
                else -> return
            }
            if (t.kind == TwoKind.SCROLL && mode == TouchMode.DIRECT) sink.movePointerTo(t.startCx, t.startCy)
        }
        when (t.kind) {
            TwoKind.PINCH -> {
                val factor = if (t.spread > 0 && spread > 0) spread / t.spread else 1f
                sink.zoom(factor, t.cx, t.cy, cx, cy)
            }
            TwoKind.SCROLL -> {
                sink.scroll(cx - t.cx, cy - t.cy, if (t.scrolled) ScrollPhase.CHANGED else ScrollPhase.BEGAN)
                t.scrolled = true
                t.samples.addLast(Triple(cx, cy, time))
                while (t.samples.isNotEmpty() && time - t.samples.first().third > 100) t.samples.removeFirst()
            }
            TwoKind.UNDECIDED -> Unit
        }
        t.cx = cx
        t.cy = cy
        t.spread = spread
    }

    private fun endTwo(t: Two, cancelled: Boolean, time: Long? = null) {
        when (t.kind) {
            TwoKind.UNDECIDED -> {
                if (!cancelled && time != null && time - t.startTime <= TAP_MILLIS && sink.isControlling) {
                    sink.click(PointerButton.SECONDARY)
                }
            }
            TwoKind.SCROLL -> if (t.scrolled) {
                val (vx, vy) = velocity(t.samples, time)
                sink.scrollEnded(vx, vy, cancelled)
            }
            TwoKind.PINCH -> Unit
        }
    }

    private fun centroid(): Pair<Float, Float> {
        val values = points.values.take(2)
        return values.sumOf { it.first.toDouble() }.toFloat() / values.size to values.sumOf { it.second.toDouble() }.toFloat() / values.size
    }

    private fun spread(cx: Float, cy: Float): Float {
        val values = points.values.take(2)
        return values.sumOf { hypot(it.first - cx, it.second - cy).toDouble() }.toFloat() / values.size
    }

    companion object {
        const val TAP_MILLIS = 350L
        const val HOLD_MILLIS = 300L

        private fun velocity(samples: ArrayDeque<Triple<Float, Float, Long>>, now: Long?): Pair<Float, Float> {
            val first = samples.firstOrNull() ?: return 0f to 0f
            val last = samples.last()
            val interval = (last.third - first.third) / 1000f
            if (interval < 0.008f || (now != null && now - last.third > 50)) return 0f to 0f
            return (last.first - first.first) / interval to (last.second - first.second) / interval
        }

        private fun speed(samples: ArrayDeque<Triple<Float, Float, Long>>): Float {
            val (vx, vy) = velocity(samples, null)
            return hypot(vx, vy)
        }

        /** OSS's pointer acceleration: faster fingers move the pointer further (1.2x to 3x). */
        fun pointerGain(speed: Float): Float = 1.2f + min(speed / 1200f, 1.8f)
    }
}

/**
 * Where the picture sits in the view (view pixels): fitted, zoomed around a point, panned, lifted above the
 * keyboard (OSS's RemoteScreenView). `zoom` is relative to fitting the whole picture in.
 */
class Viewport {
    var viewWidth = 0f; private set
    var viewHeight = 0f; private set
    var imageWidth = 0f; private set
    var imageHeight = 0f; private set
    var zoom = 1f; private set
    var offsetX = 0f; private set
    var offsetY = 0f; private set

    /** How far the picture is lifted so the pointer stays above the on-screen keyboard. */
    var lift = 0f; private set

    val fitScale: Float
        get() = if (imageWidth <= 0 || imageHeight <= 0 || viewWidth <= 0 || viewHeight <= 0) 1f
        else min(viewWidth / imageWidth, viewHeight / imageHeight)

    val scale: Float get() = fitScale * zoom

    val maxZoom: Float get() = max(6f, 3f / fitScale)

    /** The picture is shown pixel for pixel (or larger). */
    val isActualSize: Boolean get() = scale >= 0.999f && zoom > 1f

    fun layout(viewWidth: Float, viewHeight: Float, imageWidth: Float, imageHeight: Float) {
        val sameImage = imageWidth == this.imageWidth && imageHeight == this.imageHeight
        // Keep the middle of what is shown in the middle when the view changes (turning the phone).
        val centerX = if (sameImage && this.viewWidth > 0) imagePointX(this.viewWidth / 2) else imageWidth / 2
        val centerY = if (sameImage && this.viewHeight > 0) imagePointY(this.viewHeight / 2 - lift) else imageHeight / 2
        this.viewWidth = viewWidth
        this.viewHeight = viewHeight
        this.imageWidth = imageWidth
        this.imageHeight = imageHeight
        if (!sameImage) zoom = 1f
        zoom = zoom.coerceIn(1f, maxZoom)
        offsetX = viewWidth / 2 - centerX * scale
        offsetY = viewHeight / 2 - centerY * scale
        clamp()
    }

    fun fit() {
        zoom = 1f
        offsetX = 0f
        offsetY = 0f
        clamp()
    }

    /** One picture pixel per view pixel (more when the picture is smaller than the view). */
    fun actualSize(aroundX: Float = viewWidth / 2, aroundY: Float = viewHeight / 2) {
        setZoom(max(1f, 1f / fitScale), imagePointX(aroundX), imagePointY(aroundY), aroundX, aroundY)
    }

    /** Zooms to `newZoom`, keeping the picture point (`imageX`, `imageY`) at the view point (`atX`, `atY`). */
    fun setZoom(newZoom: Float, imageX: Float, imageY: Float, atX: Float, atY: Float) {
        zoom = newZoom.coerceIn(1f, maxZoom)
        offsetX = atX - imageX * scale
        offsetY = atY + lift - imageY * scale
        clamp()
    }

    fun pan(dx: Float, dy: Float) {
        offsetX += dx
        offsetY += dy
        clamp()
    }

    /** A picture smaller than the view sits in its middle; a larger one can't leave a gap at its edges. */
    private fun clamp() {
        val w = imageWidth * scale
        val h = imageHeight * scale
        offsetX = if (w <= viewWidth) (viewWidth - w) / 2 else offsetX.coerceIn(viewWidth - w, 0f)
        offsetY = if (h <= viewHeight) (viewHeight - h) / 2 else offsetY.coerceIn(viewHeight - h, 0f)
    }

    /** Where the picture's top left is drawn (with the lift). */
    val drawX: Float get() = offsetX
    val drawY: Float get() = offsetY - lift

    fun imagePointX(viewX: Float): Float = (viewX - drawX) / scale
    fun imagePointY(viewY: Float): Float = (viewY - drawY) / scale
    fun viewPointX(imageX: Float): Float = drawX + imageX * scale
    fun viewPointY(imageY: Float): Float = drawY + imageY * scale

    /** Pans so a picture point stays `margin` inside the view (the pointer when it moves out of a zoomed picture). */
    fun keepVisible(imageX: Float, imageY: Float, margin: Float) {
        val x = viewPointX(imageX)
        val y = offsetY + imageY * scale
        var dx = 0f
        var dy = 0f
        if (x < margin) dx = margin - x else if (x > viewWidth - margin) dx = viewWidth - margin - x
        if (y < margin) dy = margin - y else if (y > viewHeight - margin) dy = viewHeight - margin - y
        if (dx != 0f || dy != 0f) pan(dx, dy)
    }

    /**
     * Lifts the picture while the on-screen keyboard covers the view below `keyboardTop` (null: no keyboard) so the
     * pointer stays `margin` above it, at most until the picture's bottom reaches the keyboard (OSS).
     */
    fun liftAbove(keyboardTop: Float?, pointerImageY: Float, margin: Float) {
        if (keyboardTop == null || keyboardTop >= viewHeight) {
            lift = 0f
            return
        }
        val pointerY = offsetY + pointerImageY * scale
        val bottom = offsetY + imageHeight * scale
        val most = max(0f, bottom - keyboardTop)
        lift = (pointerY + margin - keyboardTop).coerceIn(0f, most)
    }
}
