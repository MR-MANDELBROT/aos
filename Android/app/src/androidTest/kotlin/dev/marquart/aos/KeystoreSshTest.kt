package dev.marquart.aos

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.marquart.aos.core.CompanionRequest
import dev.marquart.aos.core.CompanionSignature
import dev.marquart.aos.core.P256
import dev.marquart.aos.core.SSHKeyFormat
import dev.marquart.aos.keys.AndroidKeystoreKeys
import dev.marquart.aos.keys.KeyStorage
import dev.marquart.aos.keys.KeystoreSigner
import dev.marquart.aos.ssh.HostKeyPolicy
import dev.marquart.aos.ssh.SshConnector
import dev.marquart.aos.ssh.SshLogin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.apache.sshd.common.config.keys.KeyUtils
import org.apache.sshd.common.config.keys.PublicKeyEntry
import org.apache.sshd.common.keyprovider.KeyPairProvider
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.command.Command
import org.junit.Test
import org.junit.runner.RunWith
import java.security.KeyStore
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * On a phone or the emulator: the phone's SSH key is a non-exportable AndroidKeyStore key, and Apache MINA SSHD logs in
 * with it (the library only gets signatures, through `DeviceKeyAgent`) to a server with an ed25519 host key, both in
 * this process. Also: a companion request signed by the Keystore key checks out with its public key.
 */
@RunWith(AndroidJUnit4::class)
class KeystoreSshTest {
    @Test fun aKeystoreKeyLogsInOverSsh() {
        val context = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
        SshConnector.useHomeFolder(java.io.File(context.noBackupFilesDir, "ssh-home"))
        val keys = AndroidKeystoreKeys()
        keys.reset()
        val key = keys.sshKey()
        println("AOS-KEYSTORE storage=${key.storage} phoneId=${key.phoneId}")
        assertTrue(key.storage != KeyStorage.MEMORY)
        // The private key can't be read out
        val entry = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            .getEntry(AndroidKeystoreKeys.SSH_ALIAS, null) as KeyStore.PrivateKeyEntry
        assertNull(entry.privateKey.encoded)
        assertTrue(key.signer is KeystoreSigner)

        val hostKey = KeyUtils.generateKeyPair("ssh-ed25519", 256)
        val server = SshServer.setUpDefaultServer()
        server.host = "127.0.0.1"
        server.port = 0
        server.keyPairProvider = KeyPairProvider.wrap(hostKey)
        server.setPublickeyAuthenticator { user, offered, _ -> user == "max" && KeyUtils.compareKeys(offered, key.javaPublicKey) }
        server.setCommandFactory { _, _ ->
            object : Command {
                var out: java.io.OutputStream? = null
                var exit: org.apache.sshd.server.ExitCallback? = null
                override fun setInputStream(`in`: java.io.InputStream?) {}
                override fun setOutputStream(o: java.io.OutputStream?) { out = o }
                override fun setErrorStream(err: java.io.OutputStream?) {}
                override fun setExitCallback(callback: org.apache.sshd.server.ExitCallback?) { exit = callback }
                override fun start(channel: org.apache.sshd.server.channel.ChannelSession?, env: org.apache.sshd.server.Environment?) {
                    out!!.write("keystore-ok\n".toByteArray()); out!!.flush(); exit!!.onExit(0)
                }
                override fun destroy(channel: org.apache.sshd.server.channel.ChannelSession?) {}
            }
        }
        server.start()
        val connector = SshConnector()
        try {
            val fingerprint = SSHKeyFormat.fingerprint(PublicKeyEntry.toString(hostKey.public))!!
            runBlocking {
                withTimeout(60_000) {
                    val connection = connector.connectHosts(listOf("127.0.0.1"), server.port, SshLogin("max", key),
                        HostKeyPolicy.Fingerprint(fingerprint))
                    assertEquals("ssh-ed25519", connection.hostKeyType)
                    assertEquals("keystore-ok\n", connection.run("anything").toString(Charsets.UTF_8))
                    connection.close()
                }
            }
            // The request-signing key signs what the Mac checks
            val companion = keys.companionKey()
            val message = CompanionSignature.message(CompanionRequest.Status.signatureFields(companion.phoneId, 1, "n"))!!
            assertTrue(P256.verify(P256.publicKey(companion.publicKeyX963)!!, message, companion.sign(message)))
            println("AOS-KEYSTORE ok companionStorage=${companion.storage}")
        } finally {
            connector.shutdown()
            server.stop(true)
            keys.reset()
        }
    }
}
