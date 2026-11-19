package dev.marquart.aos.screen

import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import dev.marquart.aos.AosApp
import java.io.ByteArrayOutputStream
import java.io.File

// The Android side of the screen's shared code (shared-ui/.../screen: SessionModel, ScreenController, ScreenStore,
// DemoScreenServer). The desktop has the same declarations (desktop/.../screen/ScreenPlatform.kt).

typealias PlatformBitmap = Bitmap
typealias VideoSurface = android.view.Surface

fun uptimeMillis(): Long = SystemClock.uptimeMillis()

private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

fun postToMain(block: Runnable) {
    mainHandler.post(block)
}

object ScreenLog {
    fun info(message: String) {
        Log.i("aos-screen", message)
    }
}

object ScreenImages {
    fun framebufferBitmap(fb: Framebuffer, maxWidth: Int): Bitmap? {
        val sampled = SampledPixels.of(fb, maxWidth) ?: return null
        return Bitmap.createBitmap(sampled.pixels, sampled.width, sampled.height, Bitmap.Config.ARGB_8888)
    }

    fun jpeg(bitmap: Bitmap): ByteArray {
        val scaled = if (bitmap.width > 1280) Bitmap.createScaledBitmap(bitmap, 1280, bitmap.height * 1280 / bitmap.width, true) else bitmap
        return ByteArrayOutputStream().use {
            scaled.compress(Bitmap.CompressFormat.JPEG, 80, it)
            it.toByteArray()
        }
    }

    fun decode(jpeg: ByteArray): Bitmap? = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
}

/** The demo screen's picture, drawn with Android's Canvas. */
class DemoPicture(private val width: Int, private val height: Int) {
    private val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    private val canvas = Canvas(bitmap)

    fun background(name: String) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.shader = LinearGradient(0f, 0f, width.toFloat(), height.toFloat(), Color.rgb(0x1d, 0x3b, 0x6e), Color.rgb(0x6a, 0x2c, 0x70), Shader.TileMode.CLAMP)
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
        paint.shader = null
        paint.color = Color.argb(60, 255, 255, 255)
        for (x in 0 until width step 80) canvas.drawLine(x.toFloat(), 0f, x.toFloat(), height.toFloat(), paint)
        for (y in 0 until height step 80) canvas.drawLine(0f, y.toFloat(), width.toFloat(), y.toFloat(), paint)
        paint.color = Color.WHITE
        paint.textSize = height / 14f
        canvas.drawText(name, width * 0.06f, height * 0.18f, paint)
        paint.textSize = height / 32f
        paint.color = Color.argb(220, 255, 255, 255)
        canvas.drawText("aOS demo screen: plain RFB in the app", width * 0.06f, height * 0.26f, paint)
        canvas.drawText("Clicks paint dots, keys type below.", width * 0.06f, height * 0.31f, paint)
        paint.color = Color.argb(160, 240, 240, 240)
        canvas.drawRect(0f, 0f, width.toFloat(), height / 36f, paint)
        canvas.drawRoundRect(width * 0.25f, height * 0.9f, width * 0.75f, height * 0.98f, 20f, 20f, paint)
    }

    fun typed(text: String) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.color = Color.argb(200, 0, 0, 0)
        val top = height * 0.40f
        canvas.drawRoundRect(width * 0.05f, top, width * 0.95f, top + height * 0.08f, 12f, 12f, paint)
        paint.color = Color.WHITE
        paint.textSize = height / 24f
        canvas.drawText(text, width * 0.07f, top + height * 0.055f, paint)
    }

    fun dot(x: Int, y: Int) {
        canvas.drawCircle(x.toFloat(), y.toFloat(), 10f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(0xff, 0xc4, 0x00) })
    }

    /** ARGB pixels of a rectangle. */
    fun pixels(out: IntArray, x: Int, y: Int, w: Int, h: Int) = bitmap.getPixels(out, 0, w, x, y, w, h)
}

/** SharedPreferences as the screen store's KeyValues. */
class SharedPreferencesKeyValues(private val prefs: SharedPreferences) : KeyValues {
    override fun getBoolean(name: String, default: Boolean) = prefs.getBoolean(name, default)
    override fun getFloat(name: String, default: Float) = prefs.getFloat(name, default)
    override fun getString(name: String, default: String?): String? = prefs.getString(name, default)
    override fun putBoolean(name: String, value: Boolean) = prefs.edit().putBoolean(name, value).apply()
    override fun putFloat(name: String, value: Float) = prefs.edit().putFloat(name, value).apply()
    override fun putString(name: String, value: String) = prefs.edit().putString(name, value).apply()
    override fun remove(name: String) = prefs.edit().remove(name).apply()
    override fun all(): Map<String, Any?> = prefs.all
}

/** The app's hub, made from its Context the first time a screen view asks. */
fun ScreenHub.Companion.get(context: Context): ScreenHub = instance ?: synchronized(this) {
    instance ?: run {
        val app = context.applicationContext
        val store = ScreenStore(SharedPreferencesKeyValues(app.getSharedPreferences("screen", Context.MODE_PRIVATE)),
            SharedPreferencesKeyValues(app.getSharedPreferences("screen-records", Context.MODE_PRIVATE)), app.cacheDir,
            (app as? AosApp)?.graph?.secrets)
        ScreenHub(app, store, RemoteSessions.factory, app.cacheDir) { (app as? AosApp)?.graph?.network?.tailscaleVpnActive() == true }
            .also { instance = it }
    }
}
