package dev.marquart.aos.core

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec

/**
 * NIST P-256 with the plain JCA: keys in X9.63 form (`04 || X || Y`, what the Mac keeps), signatures as raw `r || s`
 * (64 bytes, what CryptoKit's `rawRepresentation` is and what `auth.sig` carries) and as DER (what JCA produces).
 */
object P256 {
    val p: BigInteger = BigInteger("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff", 16)
    val n: BigInteger = BigInteger("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)
    private val a: BigInteger = p - BigInteger.valueOf(3)
    private val b: BigInteger = BigInteger("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b", 16)
    private val gx: BigInteger = BigInteger("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296", 16)
    private val gy: BigInteger = BigInteger("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5", 16)

    /** The curve's parameters as JCA has them. */
    val params: ECParameterSpec by lazy {
        val parameters = AlgorithmParameters.getInstance("EC")
        parameters.init(ECGenParameterSpec("secp256r1"))
        parameters.getParameterSpec(ECParameterSpec::class.java)
    }

    /** The public key in X9.63 form: 65 bytes. */
    fun x963(key: PublicKey): ByteArray {
        val point = (key as ECPublicKey).w
        return byteArrayOf(4) + fixed32(point.affineX) + fixed32(point.affineY)
    }

    /** A public key from its X9.63 form; null when it isn't a point on P-256. */
    fun publicKey(x963: ByteArray): PublicKey? {
        if (x963.size != 65 || x963[0] != 4.toByte()) return null
        val x = BigInteger(1, x963.copyOfRange(1, 33))
        val y = BigInteger(1, x963.copyOfRange(33, 65))
        if (!isOnCurve(x, y)) return null
        return try {
            KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), params))
        } catch (_: Exception) {
            null
        }
    }

    fun isOnCurve(x: BigInteger, y: BigInteger): Boolean {
        if (x.signum() < 0 || x >= p || y.signum() < 0 || y >= p) return false
        return y.modPow(BigInteger.TWO, p) == (x.modPow(BigInteger.valueOf(3), p) + a * x + b).mod(p)
    }

    /** A private key from its 32-byte scalar (test vectors, software keys). */
    fun privateKey(scalar: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, scalar), params))

    /** The X9.63 public key that belongs to a 32-byte scalar (plain affine double-and-add; not constant time, so
     *  only for test vectors and keys being imported, never in a loop an attacker can time). */
    fun publicX963(scalar: ByteArray): ByteArray {
        val k = BigInteger(1, scalar)
        require(k.signum() > 0 && k < n) { "scalar out of range" }
        var result: Pair<BigInteger, BigInteger>? = null
        var addend: Pair<BigInteger, BigInteger>? = gx to gy
        for (i in 0 until k.bitLength()) {
            if (k.testBit(i)) result = add(result, addend)
            addend = add(addend, addend)
        }
        val (x, y) = result!!
        return byteArrayOf(4) + fixed32(x) + fixed32(y)
    }

    private fun add(p1: Pair<BigInteger, BigInteger>?, p2: Pair<BigInteger, BigInteger>?): Pair<BigInteger, BigInteger>? {
        if (p1 == null) return p2
        if (p2 == null) return p1
        val (x1, y1) = p1
        val (x2, y2) = p2
        val lambda = if (x1 == x2) {
            if ((y1 + y2).mod(p).signum() == 0) return null
            (BigInteger.valueOf(3) * x1 * x1 + a) * (BigInteger.TWO * y1).modInverse(p)
        } else {
            (y2 - y1) * (x2 - x1).modInverse(p)
        }.mod(p)
        val x3 = (lambda * lambda - x1 - x2).mod(p)
        val y3 = (lambda * (x1 - x3) - y1).mod(p)
        return x3 to y3
    }

    /** A fresh software key pair (one-time keys for the screen login; keys in tests and on the emulator). */
    fun generate(random: SecureRandom = SecureRandom()): KeyPair {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"), random)
        return generator.generateKeyPair()
    }

    /** ECDSA P-256 with SHA-256 by any JCA private key (a software key here; Keystore keys sign the same way). Raw. */
    fun sign(key: PrivateKey, message: ByteArray): ByteArray {
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(key)
        signature.update(message)
        return derToRaw(signature.sign())
    }

    /** Checks a raw `r || s` signature. */
    fun verify(publicKey: PublicKey, message: ByteArray, raw: ByteArray): Boolean {
        val der = rawToDer(raw) ?: return false
        return try {
            val signature = Signature.getInstance("SHA256withECDSA")
            signature.initVerify(publicKey)
            signature.update(message)
            signature.verify(der)
        } catch (_: Exception) {
            false
        }
    }

    /** DER `SEQUENCE { INTEGER r, INTEGER s }` to raw `r || s` (32 bytes each). */
    fun derToRaw(der: ByteArray): ByteArray {
        val (r, s) = derIntegers(der) ?: throw IllegalArgumentException("not a DER ECDSA signature")
        return fixed32(r) + fixed32(s)
    }

    /** The two integers of a DER ECDSA signature. */
    fun derIntegers(der: ByteArray): Pair<BigInteger, BigInteger>? {
        var i = 0
        fun length(): Int? {
            if (i >= der.size) return null
            val first = der[i++].toInt() and 0xFF
            if (first < 0x80) return first
            val count = first and 0x7F
            if (count == 0 || count > 2 || i + count > der.size) return null
            var value = 0
            repeat(count) { value = (value shl 8) or (der[i++].toInt() and 0xFF) }
            return value
        }
        fun integer(): BigInteger? {
            if (i >= der.size || der[i++] != 0x02.toByte()) return null
            val len = length() ?: return null
            if (len == 0 || i + len > der.size) return null
            val value = BigInteger(1, der.copyOfRange(i, i + len))
            i += len
            return value
        }
        if (der.isEmpty() || der[i++] != 0x30.toByte()) return null
        length() ?: return null
        val r = integer() ?: return null
        val s = integer() ?: return null
        return r to s
    }

    /** Raw `r || s` to DER; null when it isn't 64 bytes. */
    fun rawToDer(raw: ByteArray): ByteArray? {
        if (raw.size != 64) return null
        fun integer(bytes: ByteArray): ByteArray {
            var start = 0
            while (start < bytes.size - 1 && bytes[start] == 0.toByte()) start++
            var body = bytes.copyOfRange(start, bytes.size)
            if (body[0].toInt() and 0x80 != 0) body = byteArrayOf(0) + body
            return byteArrayOf(0x02, body.size.toByte()) + body
        }
        val content = integer(raw.copyOfRange(0, 32)) + integer(raw.copyOfRange(32, 64))
        return byteArrayOf(0x30, content.size.toByte()) + content
    }

    /** A non-negative integer as exactly 32 big-endian bytes. */
    fun fixed32(value: BigInteger): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == 32 -> bytes
            bytes.size == 33 && bytes[0] == 0.toByte() -> bytes.copyOfRange(1, 33)
            bytes.size < 32 -> ByteArray(32 - bytes.size) + bytes
            else -> throw IllegalArgumentException("more than 32 bytes")
        }
    }
}

/**
 * Something that signs with a P-256 key: a key in the Android Keystore (the private half never leaves it), or a
 * software key. Signatures are ECDSA with SHA-256, raw `r || s`.
 */
interface P256Signer {
    /** The public key, X9.63 (65 bytes). */
    val publicKeyX963: ByteArray

    /** ECDSA P-256 with SHA-256 over `message`: raw `r || s`, 64 bytes. */
    fun sign(message: ByteArray): ByteArray
}

/** A P-256 key in memory: tests, the emulator fallback, one-time keys. */
class SoftwareP256Signer(private val pair: KeyPair) : P256Signer {
    override val publicKeyX963: ByteArray = P256.x963(pair.public)
    override fun sign(message: ByteArray): ByteArray = P256.sign(pair.private, message)

    companion object {
        fun generate(): SoftwareP256Signer = SoftwareP256Signer(P256.generate())

        /** From a 32-byte scalar (reference vectors). */
        fun fromScalar(scalar: ByteArray): SoftwareP256Signer =
            SoftwareP256Signer(KeyPair(P256.publicKey(P256.publicX963(scalar))!!, P256.privateKey(scalar)))
    }
}
