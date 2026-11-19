package dev.marquart.aos.desktop.native

import com.sun.jna.Function
import com.sun.jna.Native
import com.sun.jna.Pointer
import com.sun.jna.WString
import com.sun.jna.platform.win32.Guid
import com.sun.jna.ptr.IntByReference
import com.sun.jna.ptr.PointerByReference
import com.sun.jna.win32.StdCallLibrary
import java.security.MessageDigest

/**
 * Windows Hello (face, fingerprint or the PIN) before an approval, through WinRT's UserConsentVerifier: the desktop
 * app's way is IUserConsentVerifierInterop.RequestVerificationForWindowAsync (the prompt belongs to the app's window).
 * WinRT from the JVM: COM through JNA, the vtable slots called by index, the async operation polled through IAsyncInfo.
 *
 * Why this and not a CNG key with a UI policy or CredUIPromptForWindowsCredentials: it is Windows Hello itself (the
 * gesture the person set up, also the PIN), it needs no password of the app's own, and the result says when Hello
 * isn't set up (then the approval says so, like the phone without a screen lock).
 */
object WinHello {
    enum class Result { VERIFIED, NOT_AVAILABLE, CANCELED, FAILED }

    @Suppress("FunctionName")
    private interface Combase : StdCallLibrary {
        fun RoInitialize(initType: Int): Int
        fun WindowsCreateString(sourceString: WString, length: Int, string: PointerByReference): Int
        fun WindowsDeleteString(string: Pointer?): Int
        fun RoGetActivationFactory(activatableClassId: Pointer, iid: Guid.GUID.ByReference, factory: PointerByReference): Int
    }

    private val combase: Combase by lazy { Native.load("combase", Combase::class.java) }

    private const val CLASS = "Windows.Security.Credentials.UI.UserConsentVerifier"
    private const val IID_INTEROP = "{39E050C3-4E74-441A-8DC0-B81104DF949C}"
    private const val IID_ASYNC_INFO = "{00000036-0000-0000-C000-000000000046}"
    private const val IID_ASYNC_OPERATION = "9fc2b0bb-e446-44e2-aa61-9cab8f636af2"

    /** IAsyncOperation<UserConsentVerificationResult>: a parameterized interface's IID (WinRT's SHA-1 rule). */
    val asyncOperationIid: String = parameterizedIid(
        "pinterface({$IID_ASYNC_OPERATION};enum(Windows.Security.Credentials.UI.UserConsentVerificationResult;i4))")

    /**
     * The IID of a parameterized WinRT interface from its signature: SHA-1 over the WinRT namespace GUID
     * (11f47ad5-7b73-42c0-abae-878b1e16adee) and the UTF-8 signature, as a version 5 UUID.
     */
    fun parameterizedIid(signature: String): String {
        val namespace = byteArrayOf(0x11, 0xf4.toByte(), 0x7a, 0xd5.toByte(), 0x7b, 0x73, 0x42, 0xc0.toByte(), 0xab.toByte(),
            0xae.toByte(), 0x87.toByte(), 0x8b.toByte(), 0x1e, 0x16, 0xad.toByte(), 0xee.toByte())
        val hash = MessageDigest.getInstance("SHA-1").digest(namespace + signature.toByteArray(Charsets.UTF_8)).copyOf(16)
        hash[6] = ((hash[6].toInt() and 0x0f) or 0x50).toByte()
        hash[8] = ((hash[8].toInt() and 0x3f) or 0x80).toByte()
        val hex = hash.joinToString("") { "%02x".format(it) }
        return "{${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}}".uppercase()
    }

    private fun call(obj: Pointer, slot: Int, vararg args: Any?): Int {
        val vtable = obj.getPointer(0)
        val fn = Function.getFunction(vtable.getPointer(slot.toLong() * Native.POINTER_SIZE), Function.ALT_CONVENTION)
        return fn.invokeInt(arrayOf(obj, *args))
    }

    private fun release(obj: Pointer?) {
        if (obj != null) call(obj, 2)
    }

    private fun hstring(text: String): Pointer {
        val out = PointerByReference()
        check(combase.WindowsCreateString(WString(text), text.length, out) == 0) { "WindowsCreateString" }
        return out.value
    }

    /** Blocks until the person answered (call it off the UI thread). `window`: the app's HWND (null: the foreground window). */
    fun verify(window: Pointer?, message: String): Result {
        combase.RoInitialize(1) // multithreaded; S_FALSE or RPC_E_CHANGED_MODE are fine too
        val className = hstring(CLASS)
        val text = hstring(message)
        var interop: Pointer? = null
        var operation: Pointer? = null
        var info: Pointer? = null
        try {
            val factory = PointerByReference()
            val iid = Guid.GUID.ByReference(Guid.GUID.fromString(IID_INTEROP))
            if (combase.RoGetActivationFactory(className, iid, factory) != 0) return Result.NOT_AVAILABLE
            interop = factory.value
            val hwnd = window ?: com.sun.jna.platform.win32.User32.INSTANCE.GetForegroundWindow()?.pointer
            val async = PointerByReference()
            val asyncIid = Guid.GUID.ByReference(Guid.GUID.fromString(asyncOperationIid))
            // IUserConsentVerifierInterop: IInspectable's six slots, then RequestVerificationForWindowAsync.
            if (call(interop, 6, hwnd, text, asyncIid, async) != 0) return Result.FAILED
            operation = async.value
            val infoRef = PointerByReference()
            if (call(operation, 0, Guid.GUID.ByReference(Guid.GUID.fromString(IID_ASYNC_INFO)), infoRef) != 0) return Result.FAILED
            info = infoRef.value
            val status = IntByReference()
            while (true) {
                // IAsyncInfo: IInspectable's six slots, get_Id, get_Status (7).
                if (call(info, 7, status) != 0) return Result.FAILED
                if (status.value != 0) break
                Thread.sleep(100)
            }
            if (status.value == 2) return Result.CANCELED
            if (status.value != 1) return Result.FAILED
            // IAsyncOperation<T>: IInspectable's six slots, put_Completed, get_Completed, GetResults (8).
            val result = IntByReference()
            if (call(operation, 8, result) != 0) return Result.FAILED
            return when (result.value) {
                0 -> Result.VERIFIED
                1, 2, 3 -> Result.NOT_AVAILABLE // DeviceNotPresent, NotConfiguredForUser, DisabledByPolicy
                6 -> Result.CANCELED
                else -> Result.FAILED // DeviceBusy, RetriesExhausted
            }
        } finally {
            release(info)
            release(operation)
            release(interop)
            combase.WindowsDeleteString(text)
            combase.WindowsDeleteString(className)
        }
    }
}
