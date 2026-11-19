package dev.marquart.aos.desktop.native

import com.sun.jna.Function
import com.sun.jna.NativeLibrary
import com.sun.jna.Pointer
import com.sun.jna.Structure
import com.sun.jna.ptr.PointerByReference

// The Secret Service (GNOME Keyring, KWallet) through libsecret-1 and JNA: one secret per name, under the schema
// "dev.marquart.aos.Secret" with the attribute "name". Used for the key that encrypts the app's key file and secrets
// on Linux (keys/FileKeys.kt). Null everywhere when libsecret or a Secret Service isn't there.

@Structure.FieldOrder("name", "type")
open class SecretSchemaAttribute : Structure() {
    @JvmField var name: String? = null
    @JvmField var type: Int = 0
}

@Structure.FieldOrder("name", "flags", "attributes", "reserved", "reserved1", "reserved2", "reserved3", "reserved4",
    "reserved5", "reserved6", "reserved7")
class SecretSchema : Structure() {
    @JvmField var name: String? = null
    @JvmField var flags: Int = 0
    @JvmField var attributes: Array<SecretSchemaAttribute> = Structure.newInstance(SecretSchemaAttribute::class.java).toArray(32)
        .map { it as SecretSchemaAttribute }.toTypedArray()
    @JvmField var reserved: Int = 0
    @JvmField var reserved1: Pointer? = null
    @JvmField var reserved2: Pointer? = null
    @JvmField var reserved3: Pointer? = null
    @JvmField var reserved4: Pointer? = null
    @JvmField var reserved5: Pointer? = null
    @JvmField var reserved6: Pointer? = null
    @JvmField var reserved7: Pointer? = null
}

object LibSecret {
    private val lib: NativeLibrary? by lazy { runCatching { NativeLibrary.getInstance("secret-1") }.getOrNull() }

    private val schema: SecretSchema by lazy {
        SecretSchema().apply {
            name = "dev.marquart.aos.Secret"
            flags = 0 // SECRET_SCHEMA_NONE
            attributes[0].name = "name"
            attributes[0].type = 0 // SECRET_SCHEMA_ATTRIBUTE_STRING
            write()
        }
    }

    val isAvailable: Boolean get() = lib != null

    private fun function(name: String): Function? = runCatching { lib?.getFunction(name) }.getOrNull()

    /** The secret stored under `name` (base64 text), or null. Throws when the Secret Service failed. */
    fun lookup(name: String): String? {
        val fn = function("secret_password_lookup_sync") ?: return null
        val error = PointerByReference()
        val result = fn.invokePointer(arrayOf(schema, null, error, "name", name, null))
        if (error.value != null) throw IllegalStateException("Secret Service: lookup failed")
        val text = result?.getString(0)
        if (result != null) function("secret_password_free")?.invokeVoid(arrayOf(result))
        return text
    }

    /** Stores `secret` under `name` in the default collection. Throws when the Secret Service failed. */
    fun store(name: String, label: String, secret: String) {
        val fn = function("secret_password_store_sync") ?: throw IllegalStateException("no libsecret")
        val error = PointerByReference()
        val ok = fn.invokeInt(arrayOf(schema, null, label, secret, null, error, "name", name, null))
        if (ok == 0 || error.value != null) throw IllegalStateException("Secret Service: store failed")
    }

    fun clear(name: String) {
        val fn = function("secret_password_clear_sync") ?: return
        val error = PointerByReference()
        fn.invokeInt(arrayOf(schema, null, error, "name", name, null))
    }
}
