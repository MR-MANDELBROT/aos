package dev.marquart.aos.desktop.native

import com.sun.jna.Callback
import com.sun.jna.Library
import com.sun.jna.Memory
import com.sun.jna.Native
import com.sun.jna.Pointer
import com.sun.jna.Structure
import com.sun.jna.ptr.PointerByReference
import java.io.File

/**
 * Linux: checks the account's password with PAM (libpam through JNA), for the setting "Confirm with the password".
 * The service: /etc/pam.d/aos when the package installed it (it includes common-auth), else "login". pam_unix checks
 * the password of the user running the app through its setuid helper (unix_chkpwd), no root needed.
 */
object Pam {
    @Suppress("FunctionName")
    private interface LibPam : Library {
        fun pam_start(service: String, user: String, conversation: PamConv, handle: PointerByReference): Int
        fun pam_authenticate(handle: Pointer, flags: Int): Int
        fun pam_end(handle: Pointer, status: Int): Int
    }

    interface ConvCallback : Callback {
        fun invoke(count: Int, messages: Pointer, responses: PointerByReference, data: Pointer?): Int
    }

    @Structure.FieldOrder("conv", "appdata")
    class PamConv : Structure() {
        @JvmField var conv: ConvCallback? = null
        @JvmField var appdata: Pointer? = null
    }

    private val lib: LibPam? by lazy { runCatching { Native.load("pam", LibPam::class.java) }.getOrNull() }

    val isAvailable: Boolean get() = lib != null

    val service: String get() = if (File("/etc/pam.d/aos").isFile) "aos" else "login"

    /** True when `password` is the password of `user`. Blocks (PAM may wait a few seconds after a wrong one). */
    fun check(user: String, password: CharArray): Boolean {
        val pam = lib ?: return false
        val callback = object : ConvCallback {
            override fun invoke(count: Int, messages: Pointer, responses: PointerByReference, data: Pointer?): Int {
                // struct pam_response { char *resp; int resp_retcode; }: PAM frees what it gets, so libc's calloc.
                val size = Native.POINTER_SIZE * 2L
                val block = Native.malloc(size * count)
                if (block == 0L) return 5 // PAM_BUF_ERR
                val array = Pointer(block)
                array.clear(size * count)
                for (i in 0 until count) {
                    val message = messages.getPointer(i.toLong() * Native.POINTER_SIZE)
                    val style = message.getInt(0)
                    if (style == 1 /* PAM_PROMPT_ECHO_OFF */ || style == 2 /* PAM_PROMPT_ECHO_ON */) {
                        val bytes = String(password).toByteArray()
                        val text = Native.malloc(bytes.size + 1L)
                        Pointer(text).write(0, bytes, 0, bytes.size)
                        Pointer(text).setByte(bytes.size.toLong(), 0)
                        array.setPointer(i * size, Pointer(text))
                    }
                }
                responses.value = array
                return 0
            }
        }
        val conversation = PamConv().apply { conv = callback; write() }
        val handle = PointerByReference()
        if (pam.pam_start(service, user, conversation, handle) != 0) return false
        val status = pam.pam_authenticate(handle.value, 0)
        pam.pam_end(handle.value, status)
        return status == 0
    }
}
