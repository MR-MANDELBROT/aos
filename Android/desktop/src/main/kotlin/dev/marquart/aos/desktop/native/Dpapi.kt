package dev.marquart.aos.desktop.native

import com.sun.jna.platform.win32.Crypt32Util
import dev.marquart.aos.desktop.store.Sealer

/** Windows: values sealed with DPAPI for this user (CryptProtectData), the value's name as extra entropy. */
object DpapiSealer : Sealer {
    override val kind = Sealer.Kind.DPAPI
    private const val UI_FORBIDDEN = 0x1

    override fun seal(value: ByteArray, name: String): ByteArray =
        Crypt32Util.cryptProtectData(value, name.toByteArray(), UI_FORBIDDEN, "aOS", null)

    override fun open(sealed: ByteArray, name: String): ByteArray =
        Crypt32Util.cryptUnprotectData(sealed, name.toByteArray(), UI_FORBIDDEN, null)
}
