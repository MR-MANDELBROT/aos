// What the Screen tab keeps: its settings, what each screen's sessions recorded (the device's model, when it was last
// connected, the screen sharing key it trusts, clipboard and quality), the Mac's screen login (encrypted, behind the
// phone's lock) and the last pictures (cacheDir/Screen). Written for aOS's Android app on 2026-11-19 after
// iOS/Sources/Screen (ScreenPictures, ScreenSettings) and Open Screen Sharing's ComputerStore (GPL-3.0, nekohasekai).

package dev.marquart.aos.screen

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import dev.marquart.aos.store.SecretStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/** What a screen's sessions recorded (no user name or password). */
@Serializable
data class ScreenRecord(
    val macId: String = "",
    val model: String = "",
    val lastConnected: Long? = null,
    val trustedFingerprint: String = "",
    val sharesClipboard: Boolean? = null,
    val fullQuality: Boolean = false,
) {
    val knowsServerKey: Boolean get() = trustedFingerprint.isNotEmpty()
}

/** The Mac account for the Mac's own screen sharing. */
@Serializable
data class MacLogin(val username: String, val password: String) {
    override fun toString() = "MacLogin(username=$username, password=<hidden>)"
}

class ScreenStore(context: Context, private val secrets: SecretStore?) {
    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("screen", Context.MODE_PRIVATE)
    private val records = app.getSharedPreferences("screen-records", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    // Settings: one for both screens, as on the iPhone

    private val _matchesPhone = MutableStateFlow(prefs.getBoolean("matchesPhone", true))
    private val _resolutionScale = MutableStateFlow(prefs.getFloat("resolutionScale", 1f).toDouble())
    private val _touchMode = MutableStateFlow(TouchMode.from(prefs.getString("touchMode", null)))

    /** Both screens take the phone's shape (the workspace through aOS's display request, the Mac's virtual display). */
    val matchesPhone: StateFlow<Boolean> = _matchesPhone.asStateFlow()
    val resolutionScale: StateFlow<Double> = _resolutionScale.asStateFlow()
    val touchMode: StateFlow<TouchMode> = _touchMode.asStateFlow()

    fun setMatchesPhone(value: Boolean) {
        _matchesPhone.value = value
        prefs.edit().putBoolean("matchesPhone", value).apply()
    }

    fun setResolutionScale(value: Double) {
        _resolutionScale.value = value
        prefs.edit().putFloat("resolutionScale", value.toFloat()).apply()
    }

    fun setTouchMode(value: TouchMode) {
        _touchMode.value = value
        prefs.edit().putString("touchMode", value.raw).apply()
    }

    // Records

    fun record(id: String): ScreenRecord? =
        records.getString(id, null)?.let { runCatching { json.decodeFromString(ScreenRecord.serializer(), it) }.getOrNull() }

    fun update(id: String, macId: String, change: (ScreenRecord) -> ScreenRecord) {
        val next = change(record(id) ?: ScreenRecord(macId = macId))
        records.edit().putString(id, json.encodeToString(ScreenRecord.serializer(), next)).apply()
        revision++
    }

    /** Forgets what was kept for the screens of Macs that are no longer paired (and their pictures, their login). */
    suspend fun forgetAllBut(macIds: Set<String>) {
        for ((id, value) in records.all) {
            val record = (value as? String)?.let { runCatching { json.decodeFromString(ScreenRecord.serializer(), it) }.getOrNull() }
            if (record != null && record.macId.isNotEmpty() && record.macId !in macIds) {
                records.edit().remove(id).apply()
                forgetPicture(id)
                secrets?.put(loginKey(record.macId), null)
            }
        }
    }

    // The Mac's login (SecretStore: AES-GCM with a Keystore key; the prompt before reading is the tab's)

    private fun loginKey(macId: String) = "screen-login-$macId"

    suspend fun macLogin(macId: String): MacLogin? = secrets?.get(loginKey(macId))?.let {
        runCatching { json.decodeFromString(MacLogin.serializer(), String(it)) }.getOrNull()
    }

    suspend fun hasMacLogin(macId: String): Boolean = secrets?.get(loginKey(macId)) != null

    suspend fun setMacLogin(macId: String, login: MacLogin?) {
        secrets?.put(loginKey(macId), login?.let { json.encodeToString(MacLogin.serializer(), it).toByteArray() })
    }

    // Pictures: one JPEG per screen in cacheDir/Screen (what was on a screen can be private: not in backups, gone with
    // the cache)

    var revision by mutableIntStateOf(0)
        private set
    private val pictures = HashMap<String, Bitmap?>()
    private val pictureDir = File(app.cacheDir, "Screen")

    fun picture(id: String): Bitmap? {
        @Suppress("UNUSED_EXPRESSION") revision
        synchronized(pictures) {
            if (id in pictures) return pictures[id]
        }
        val file = File(pictureDir, "$id.jpg")
        val bitmap = if (file.isFile) BitmapFactory.decodeFile(file.path) else null
        synchronized(pictures) { pictures[id] = bitmap }
        return bitmap
    }

    fun savePicture(id: String, jpeg: ByteArray) {
        val bitmap = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return
        synchronized(pictures) { pictures[id] = bitmap }
        revision++
        Thread {
            runCatching {
                pictureDir.mkdirs()
                val file = File(pictureDir, "$id.jpg")
                val temp = File(pictureDir, "$id.tmp")
                temp.writeBytes(jpeg)
                temp.renameTo(file)
            }
        }.start()
    }

    fun forgetPicture(id: String) {
        synchronized(pictures) { pictures.remove(id) }
        File(pictureDir, "$id.jpg").delete()
        revision++
    }
}
