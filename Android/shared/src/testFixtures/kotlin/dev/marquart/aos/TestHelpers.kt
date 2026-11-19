package dev.marquart.aos

import dev.marquart.aos.core.P256Signer
import dev.marquart.aos.core.SoftwareP256Signer
import dev.marquart.aos.keys.DeviceKey
import dev.marquart.aos.keys.KeyStorage
import kotlinx.coroutines.delay
import java.util.concurrent.atomic.AtomicInteger

// Helpers for the tests of :shared, :app and :desktop.

/** Polls a condition (the connection's state machine runs on its own dispatcher). */
suspend fun waitUntil(timeoutMillis: Long = 10_000, what: String = "condition", condition: () -> Boolean) {
    val deadline = System.currentTimeMillis() + timeoutMillis
    while (!condition()) {
        if (System.currentTimeMillis() > deadline) throw AssertionError("$what not met within $timeoutMillis ms")
        delay(25)
    }
}

/** A signer that holds only a function, as a Keystore key does: the SSH library can't get at any private key. */
class HandleOnlySigner(private val inner: P256Signer = SoftwareP256Signer.generate()) : P256Signer {
    val signatures = AtomicInteger(0)
    override val publicKeyX963: ByteArray get() = inner.publicKeyX963
    override fun sign(message: ByteArray): ByteArray = inner.sign(message).also { signatures.incrementAndGet() }
}

fun testKey(signer: P256Signer = HandleOnlySigner()) = DeviceKey(signer, KeyStorage.MEMORY)

