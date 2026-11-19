// The picture on the phone's screen with OpenGL ES 3: libsharing's framebuffer (standard mode) as a texture that only
// takes the rectangles that changed, or the high performance video from MediaCodec through a SurfaceTexture, and the
// Mac's pointer on top. Written for aOS's Android app on 2026-11-19 in the place of Open Screen Sharing's Metal
// renderer (SessionUI/ScreenRenderer.swift, GPL-3.0, nekohasekai).

package dev.marquart.aos.screen

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.opengl.GLSurfaceView
import android.opengl.GLUtils
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.PixelCopy
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.max
import kotlin.math.roundToInt

/** Where the picture goes in the view (view pixels), published by the view for the GL thread. */
data class PictureTransform(val viewWidth: Float, val viewHeight: Float, val x: Float, val y: Float, val scale: Float)

class ScreenRenderer(private val view: GLSurfaceView, private val density: Float) : GLSurfaceView.Renderer, PictureSink {
    @Volatile var session: SessionModel? = null
    @Volatile var transform = PictureTransform(0f, 0f, 0f, 0f, 1f)
    /** The renderer's video surface came or went (main thread). */
    var onVideoSurface: (Surface?) -> Unit = {}

    private val lock = Any()
    private var pendingFramebuffer: Framebuffer? = null
    private var framebufferChanged = false
    private var dirtyLeft = 0
    private var dirtyTop = 0
    private var dirtyRight = 0
    private var dirtyBottom = 0
    private var hasDirty = false
    @Volatile private var cursorChanged = true
    @Volatile private var video = false
    @Volatile private var videoFrame = false

    // GL thread
    private var framebuffer: Framebuffer? = null
    private var programPicture = 0
    private var programVideo = 0
    private var programCursor = 0
    private var pictureTexture = 0
    private var videoTexture = 0
    private var cursorTexture = 0
    private var arrowTexture = 0
    private var cursorSize = Triple(0, 0, Pair(0, 0))
    private var arrowSize = Triple(0, 0, Pair(0, 0))
    private var cursorFromMac = false
    private var textureWidth = 0
    private var textureHeight = 0
    private var maxTextureSize = 4096
    private var surfaceTexture: SurfaceTexture? = null
    private var surface: Surface? = null
    private val videoMatrix = FloatArray(16)
    private var hasVideoFrame = false
    private val main = Handler(Looper.getMainLooper())
    private val quad: FloatBuffer = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
        put(floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f))
        position(0)
    }

    // PictureSink (libsharing's threads and the main thread)

    override fun framebufferChanged(framebuffer: Framebuffer) {
        synchronized(lock) {
            pendingFramebuffer = framebuffer
            framebufferChanged = true
            hasDirty = false
        }
        view.requestRender()
    }

    override fun framebufferDirty(x: Int, y: Int, width: Int, height: Int) {
        synchronized(lock) {
            if (!hasDirty) {
                dirtyLeft = x; dirtyTop = y; dirtyRight = x + width; dirtyBottom = y + height
                hasDirty = true
            } else {
                dirtyLeft = minOf(dirtyLeft, x); dirtyTop = minOf(dirtyTop, y)
                dirtyRight = maxOf(dirtyRight, x + width); dirtyBottom = maxOf(dirtyBottom, y + height)
            }
        }
        view.requestRender()
    }

    override fun cursorChanged() {
        cursorChanged = true
        view.requestRender()
    }

    override fun redraw() = view.requestRender()

    override fun videoChanged(active: Boolean) {
        video = active
        if (!active) hasVideoFrame = false
        view.requestRender()
    }

    override fun captureVideo(done: (Bitmap?) -> Unit) {
        val t = transform
        val session = session ?: return done(null)
        val w = (session.imageWidth * t.scale).roundToInt()
        val h = (session.imageHeight * t.scale).roundToInt()
        val left = t.x.roundToInt().coerceAtLeast(0)
        val top = t.y.roundToInt().coerceAtLeast(0)
        val right = (left + w).coerceAtMost(t.viewWidth.toInt())
        val bottom = (top + h).coerceAtMost(t.viewHeight.toInt())
        if (right <= left || bottom <= top || !view.holder.surface.isValid) return done(null)
        val bitmap = Bitmap.createBitmap(right - left, bottom - top, Bitmap.Config.ARGB_8888)
        try {
            PixelCopy.request(view, android.graphics.Rect(left, top, right, bottom), bitmap, { result ->
                done(if (result == PixelCopy.SUCCESS) bitmap else null)
            }, main)
        } catch (_: Exception) {
            done(null)
        }
    }

    // GLSurfaceView.Renderer

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        programPicture = program(VERTEX, FRAGMENT_PICTURE)
        programVideo = program(VERTEX_VIDEO, FRAGMENT_VIDEO)
        programCursor = program(VERTEX, FRAGMENT_CURSOR)
        val ids = IntArray(4)
        GLES30.glGenTextures(4, ids, 0)
        pictureTexture = ids[0]; videoTexture = ids[1]; cursorTexture = ids[2]; arrowTexture = ids[3]
        for (t in listOf(pictureTexture, cursorTexture, arrowTexture)) {
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, t)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        }
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, videoTexture)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        val max = IntArray(1)
        GLES30.glGetIntegerv(GLES30.GL_MAX_TEXTURE_SIZE, max, 0)
        maxTextureSize = max[0]
        arrowSize = upload(arrowTexture, arrowBitmap())
        textureWidth = 0
        textureHeight = 0
        // The framebuffer goes up whole again into the new context.
        synchronized(lock) {
            if (pendingFramebuffer == null) pendingFramebuffer = framebuffer ?: session?.framebuffer
            framebufferChanged = pendingFramebuffer != null
        }
        cursorChanged = true
        val texture = SurfaceTexture(videoTexture)
        texture.setOnFrameAvailableListener {
            videoFrame = true
            view.requestRender()
        }
        val s = Surface(texture)
        surfaceTexture?.release()
        surface?.release()
        surfaceTexture = texture
        surface = s
        main.post { onVideoSurface(s) }
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES30.glViewport(0, 0, width, height)
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES30.glClearColor(0f, 0f, 0f, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        val session = session ?: return
        val t = transform
        if (t.viewWidth <= 0 || t.viewHeight <= 0) return
        if (video) drawVideo(session, t) else drawFramebuffer(t)
        drawCursor(session, t)
    }

    /** The view is going away: the video surface with it. */
    fun release() {
        main.post { onVideoSurface(null) }
        surface?.release()
        surfaceTexture?.release()
        surface = null
        surfaceTexture = null
    }

    private fun drawFramebuffer(t: PictureTransform) {
        var fb: Framebuffer?
        var whole: Boolean
        var l = 0; var tp = 0; var r = 0; var b = 0
        var dirty: Boolean
        synchronized(lock) {
            whole = framebufferChanged
            if (whole) framebuffer = pendingFramebuffer
            fb = framebuffer
            framebufferChanged = false
            dirty = hasDirty
            if (dirty) { l = dirtyLeft; tp = dirtyTop; r = dirtyRight; b = dirtyBottom }
            hasDirty = false
        }
        val frame = fb ?: return
        if (frame.width > maxTextureSize || frame.height > maxTextureSize) {
            Log.w("aos-screen", "picture ${frame.width}x${frame.height} is larger than the GPU's textures ($maxTextureSize)")
        }
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, pictureTexture)
        GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 4)
        GLES30.glPixelStorei(GLES30.GL_UNPACK_ROW_LENGTH, frame.bytesPerRow / 4)
        if (whole || textureWidth != frame.width || textureHeight != frame.height) {
            GLES30.glPixelStorei(GLES30.GL_UNPACK_SKIP_PIXELS, 0)
            GLES30.glPixelStorei(GLES30.GL_UNPACK_SKIP_ROWS, 0)
            GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA, frame.width, frame.height, 0, GLES30.GL_RGBA,
                GLES30.GL_UNSIGNED_BYTE, frame.pixels.duplicate().position(0))
            textureWidth = frame.width
            textureHeight = frame.height
        } else if (dirty) {
            val x = l.coerceIn(0, frame.width)
            val y = tp.coerceIn(0, frame.height)
            val w = r.coerceIn(x, frame.width) - x
            val h = b.coerceIn(y, frame.height) - y
            if (w > 0 && h > 0) {
                // Only the rectangle that changed, read straight from libsharing's buffer (no copy).
                GLES30.glPixelStorei(GLES30.GL_UNPACK_SKIP_PIXELS, x)
                GLES30.glPixelStorei(GLES30.GL_UNPACK_SKIP_ROWS, y)
                GLES30.glTexSubImage2D(GLES30.GL_TEXTURE_2D, 0, x, y, w, h, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE,
                    frame.pixels.duplicate().position(0))
            }
        }
        GLES30.glPixelStorei(GLES30.GL_UNPACK_ROW_LENGTH, 0)
        GLES30.glPixelStorei(GLES30.GL_UNPACK_SKIP_PIXELS, 0)
        GLES30.glPixelStorei(GLES30.GL_UNPACK_SKIP_ROWS, 0)
        val scale = t.scale
        // Pixels on the screen's grid: sharp at 1:1, smooth when scaled
        val filter = if (kotlin.math.abs(scale - 1f) < 0.001f || scale >= 2f) GLES30.GL_NEAREST else GLES30.GL_LINEAR
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, filter)
        GLES30.glDisable(GLES30.GL_BLEND)
        quad(programPicture, t, t.x, t.y, frame.width * scale, frame.height * scale)
    }

    private fun drawVideo(session: SessionModel, t: PictureTransform) {
        val texture = surfaceTexture ?: return
        if (videoFrame) {
            videoFrame = false
            try {
                texture.updateTexImage()
                texture.getTransformMatrix(videoMatrix)
                hasVideoFrame = true
            } catch (e: Exception) {
                return
            }
        }
        if (!hasVideoFrame || session.imageWidth <= 0) return
        GLES30.glUseProgram(programVideo)
        GLES30.glUniformMatrix4fv(GLES30.glGetUniformLocation(programVideo, "uTexMatrix"), 1, false, videoMatrix, 0)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, videoTexture)
        GLES30.glDisable(GLES30.GL_BLEND)
        quad(programVideo, t, t.x, t.y, session.imageWidth * t.scale, session.imageHeight * t.scale)
    }

    private fun drawCursor(session: SessionModel, t: PictureTransform) {
        if (!session.pointerVisible || !session.hasPicture) return
        if (cursorChanged) {
            cursorChanged = false
            val cursor = session.cursor
            cursorFromMac = cursor != null
            if (cursor != null) {
                GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, cursorTexture)
                GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 4)
                GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA, cursor.width, cursor.height, 0, GLES30.GL_RGBA,
                    GLES30.GL_UNSIGNED_BYTE, ByteBuffer.wrap(cursor.pixels))
                cursorSize = Triple(cursor.width, cursor.height, cursor.hotspotX to cursor.hotspotY)
            }
        }
        val (w, h, hotspot) = if (cursorFromMac) cursorSize else arrowSize
        if (w <= 0 || h <= 0) return
        // The Mac's pointer in the picture's pixels, but never smaller than 18 dp on the phone.
        val factor = if (cursorFromMac) max(t.scale, 18f * density / h) else density * 22f / h
        val x = t.x + session.pointerX * t.scale - hotspot.first * factor
        val y = t.y + session.pointerY * t.scale - hotspot.second * factor
        GLES30.glEnable(GLES30.GL_BLEND)
        GLES30.glBlendFunc(GLES30.GL_ONE, GLES30.GL_ONE_MINUS_SRC_ALPHA)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, if (cursorFromMac) cursorTexture else arrowTexture)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glUseProgram(programCursor)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(programCursor, "uSwap"), if (cursorFromMac) 1 else 0)
        quad(programCursor, t, x, y, w * factor, h * factor)
        GLES30.glDisable(GLES30.GL_BLEND)
    }

    /** Draws the bound texture into the view rectangle (`x`, `y`, `w`, `h`) in view pixels. */
    private fun quad(program: Int, t: PictureTransform, x: Float, y: Float, w: Float, h: Float) {
        GLES30.glUseProgram(program)
        val left = x / t.viewWidth * 2 - 1
        val right = (x + w) / t.viewWidth * 2 - 1
        val top = 1 - y / t.viewHeight * 2
        val bottom = 1 - (y + h) / t.viewHeight * 2
        GLES30.glUniform4f(GLES30.glGetUniformLocation(program, "uRect"), left, top, right, bottom)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(program, "uTexture"), 0)
        val position = GLES30.glGetAttribLocation(program, "aCorner")
        GLES30.glEnableVertexAttribArray(position)
        GLES30.glVertexAttribPointer(position, 2, GLES30.GL_FLOAT, false, 0, quad)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        GLES30.glDisableVertexAttribArray(position)
    }

    private fun upload(texture: Int, bitmap: Bitmap): Triple<Int, Int, Pair<Int, Int>> {
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture)
        GLUtils.texImage2D(GLES30.GL_TEXTURE_2D, 0, bitmap, 0)
        val size = Triple(bitmap.width, bitmap.height, 2 to 2)
        bitmap.recycle()
        return size
    }

    /** A plain arrow pointer for before the Mac sends its own. */
    private fun arrowBitmap(): Bitmap {
        val bitmap = Bitmap.createBitmap(26, 38, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val path = Path().apply {
            moveTo(2f, 2f); lineTo(2f, 30f); lineTo(9f, 23f); lineTo(14f, 34f); lineTo(19f, 32f); lineTo(14f, 21f)
            lineTo(23f, 21f); close()
        }
        canvas.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK; style = Paint.Style.FILL })
        canvas.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 2f })
        return bitmap
    }

    private fun program(vertex: String, fragment: String): Int {
        fun shader(type: Int, source: String): Int {
            val s = GLES30.glCreateShader(type)
            GLES30.glShaderSource(s, source)
            GLES30.glCompileShader(s)
            val ok = IntArray(1)
            GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0)
            if (ok[0] == 0) Log.e("aos-screen", "shader: " + GLES30.glGetShaderInfoLog(s))
            return s
        }
        val p = GLES30.glCreateProgram()
        GLES30.glAttachShader(p, shader(GLES30.GL_VERTEX_SHADER, vertex))
        GLES30.glAttachShader(p, shader(GLES30.GL_FRAGMENT_SHADER, fragment))
        GLES30.glLinkProgram(p)
        return p
    }

    companion object {
        private const val VERTEX = """#version 300 es
in vec2 aCorner;
uniform vec4 uRect;
out vec2 vUV;
void main() {
    vUV = aCorner;
    gl_Position = vec4(mix(uRect.x, uRect.z, aCorner.x), mix(uRect.y, uRect.w, aCorner.y), 0.0, 1.0);
}"""

        // libsharing's pixels are B, G, R, X in memory, uploaded as RGBA: swizzled back, drawn opaque.
        private const val FRAGMENT_PICTURE = """#version 300 es
precision mediump float;
in vec2 vUV;
uniform sampler2D uTexture;
out vec4 color;
void main() {
    vec4 c = texture(uTexture, vUV);
    color = vec4(c.b, c.g, c.r, 1.0);
}"""

        private const val FRAGMENT_CURSOR = """#version 300 es
precision mediump float;
in vec2 vUV;
uniform sampler2D uTexture;
uniform int uSwap;
out vec4 color;
void main() {
    vec4 c = texture(uTexture, vUV);
    color = uSwap == 1 ? c.bgra : c;
}"""

        private const val VERTEX_VIDEO = """#version 300 es
in vec2 aCorner;
uniform vec4 uRect;
uniform mat4 uTexMatrix;
out vec2 vUV;
void main() {
    vUV = (uTexMatrix * vec4(aCorner.x, 1.0 - aCorner.y, 0.0, 1.0)).xy;
    gl_Position = vec4(mix(uRect.x, uRect.z, aCorner.x), mix(uRect.y, uRect.w, aCorner.y), 0.0, 1.0);
}"""

        private const val FRAGMENT_VIDEO = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
in vec2 vUV;
uniform samplerExternalOES uTexture;
out vec4 color;
void main() {
    color = vec4(texture(uTexture, vUV).rgb, 1.0);
}"""
    }
}
