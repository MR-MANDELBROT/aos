package dev.marquart.aos.ssh

import dev.marquart.aos.core.P256
import dev.marquart.aos.keys.DeviceKey
import org.apache.sshd.agent.SshAgent
import org.apache.sshd.agent.SshAgentFactory
import org.apache.sshd.agent.SshAgentKeyConstraint
import org.apache.sshd.agent.SshAgentServer
import org.apache.sshd.common.FactoryManager
import org.apache.sshd.common.channel.ChannelFactory
import org.apache.sshd.common.session.ConnectionService
import org.apache.sshd.common.session.Session
import org.apache.sshd.common.session.SessionContext
import org.apache.sshd.common.util.buffer.ByteArrayBuffer
import java.io.IOException
import java.math.BigInteger
import java.security.KeyPair
import java.security.PublicKey
import java.util.AbstractMap

/**
 * The phone's SSH key offered to MINA as an in-process SSH agent: MINA asks it for the public key and for a signature
 * over the login data, and never sees a private key. That is how a Keystore key (whose private half can't leave the
 * Keystore) logs in: `DeviceKey.sign` runs `SHA256withECDSA` on the Keystore's handle.
 *
 * One agent per connection (MINA asks the factory per session); the key comes from the connection's setup.
 */
internal class DeviceKeyAgent(private val key: DeviceKey) : SshAgent {
    @Volatile private var open = true

    override fun getIdentities(): Iterable<Map.Entry<PublicKey, String>> =
        listOf(AbstractMap.SimpleImmutableEntry(key.javaPublicKey, "aOS"))

    override fun sign(session: SessionContext?, publicKey: PublicKey, algo: String?, data: ByteArray): Map.Entry<String, ByteArray> {
        if (!open) throw IOException("agent closed")
        if (!P256.x963(publicKey).contentEquals(key.publicKeyX963)) throw IOException("not this phone's key")
        val raw = key.sign(data)
        // SSH's ecdsa signature blob (RFC 5656 3.1.2): mpint r, mpint s.
        val blob = ByteArrayBuffer()
        blob.putMPInt(BigInteger(1, raw.copyOfRange(0, 32)))
        blob.putMPInt(BigInteger(1, raw.copyOfRange(32, 64)))
        return AbstractMap.SimpleImmutableEntry(KEY_TYPE, blob.compactData)
    }

    /** Never: the private key isn't here. */
    override fun resolveLocalIdentity(key: PublicKey?): KeyPair? = null

    override fun addIdentity(key: KeyPair?, comment: String?, vararg constraints: SshAgentKeyConstraint?) =
        throw UnsupportedOperationException("the phone's key is fixed")

    override fun removeIdentity(key: PublicKey?) = throw UnsupportedOperationException("the phone's key is fixed")
    override fun removeAllIdentities() = throw UnsupportedOperationException("the phone's key is fixed")
    override fun isOpen() = open
    override fun close() {
        open = false
    }

    companion object {
        const val KEY_TYPE = "ecdsa-sha2-nistp256"
    }
}

/** Makes a `DeviceKeyAgent` for each session from its setup. No agent forwarding: no channel factories, no server. */
internal object DeviceKeyAgentFactory : SshAgentFactory {
    override fun getChannelForwardingFactories(manager: FactoryManager?): List<ChannelFactory> = emptyList()

    override fun createClient(session: Session?, manager: FactoryManager?): SshAgent {
        val setup = SshConnector.setupOf(session) ?: throw IOException("no login for this session")
        return DeviceKeyAgent(setup.login.key)
    }

    override fun createServer(service: ConnectionService?): SshAgentServer = throw IOException("no agent forwarding")
}
