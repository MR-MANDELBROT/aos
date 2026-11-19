package dev.marquart.aos.desktop

import dev.marquart.aos.R
import dev.marquart.aos.core.P256
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.desktop.connection.PollingNetworkMonitor
import dev.marquart.aos.desktop.keys.FileKeys
import dev.marquart.aos.desktop.keys.KeyFile
import dev.marquart.aos.desktop.native.CngKey
import dev.marquart.aos.desktop.native.WinHello
import dev.marquart.aos.desktop.screen.DesktopKeys
import dev.marquart.aos.desktop.store.DesktopSecretStore
import dev.marquart.aos.desktop.store.FileMacStore
import dev.marquart.aos.desktop.store.FileSettingsStore
import dev.marquart.aos.desktop.store.PlainSealer
import dev.marquart.aos.desktop.store.Prefs
import dev.marquart.aos.desktop.store.Sealer
import dev.marquart.aos.desktop.system.SingleInstance
import dev.marquart.aos.keys.KeyStorage
import dev.marquart.aos.screen.Keysym
import dev.marquart.aos.screen.ModifierKey
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.security.SecureRandom
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import java.awt.event.KeyEvent as Awt
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The desktop's own pieces that run on any system (this Mac in development): files, keys, texts, keys, IIDs. */
class DesktopPiecesTests {
    private fun tempDir(): File = Files.createTempDirectory("aos-desktop-test").toFile().also { it.deleteOnExit() }

    /** A sealer like the Secret Service's (AES-GCM, a key in memory). */
    private class TestSealer : Sealer {
        private val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        override val kind = Sealer.Kind.SECRET_SERVICE
        override fun seal(value: ByteArray, name: String): ByteArray {
            val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            c.updateAAD(name.toByteArray())
            return nonce + c.doFinal(value)
        }
        override fun open(sealed: ByteArray, name: String): ByteArray {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, sealed, 0, 12))
            c.updateAAD(name.toByteArray())
            return c.doFinal(sealed, 12, sealed.size - 12)
        }
    }

    private fun mode(file: File) = PosixFilePermissions.toString(Files.getPosixFilePermissions(file.toPath()))

    @Test fun keyFilesAreMadeOnceKeptPrivateAndSign() {
        val dir = tempDir()
        val keys = FileKeys(File(dir, "keys"), PlainSealer)
        val ssh = keys.sshKey()
        assertEquals(KeyStorage.FILE, ssh.storage)
        assertNotEquals(ssh.phoneId, keys.companionKey().phoneId)
        assertEquals("rw-------", mode(File(dir, "keys/ssh.key")))
        assertEquals("rwx------", mode(File(dir, "keys")))
        // A new provider over the same folder reads the same keys.
        val again = FileKeys(File(dir, "keys"), PlainSealer)
        assertEquals(ssh.openSSHPublicKey, again.sshKey().openSSHPublicKey)
        val message = "hello".toByteArray()
        assertTrue(P256.verify(ssh.javaPublicKey, message, again.sshKey().sign(message)))
        keys.reset()
        assertFalse(File(dir, "keys/ssh.key").exists())
    }

    @Test fun keyFilesSealedWithTheKeyring() {
        val dir = tempDir()
        val sealer = TestSealer()
        val keys = FileKeys(File(dir, "keys"), sealer)
        assertEquals(KeyStorage.FILE_ENCRYPTED, keys.sshKey().storage)
        val bytes = File(dir, "keys/ssh.key").readBytes()
        assertEquals(1, bytes[5].toInt(), "sealed")
        val (scalar, sealed) = KeyFile.read(bytes, "ssh", sealer)
        assertTrue(sealed)
        assertEquals(32, scalar.size)
        // Without the keyring's key the file doesn't open (another sealer, another key).
        assertFailsWith<Exception> { KeyFile.read(bytes, "ssh", TestSealer()) }
        assertFailsWith<IllegalArgumentException> { KeyFile.read("nonsense".toByteArray(), "ssh", sealer) }
    }

    @Test fun storesRoundTripInPrivateFiles() = runBlocking {
        val dir = tempDir()
        val macs = FileMacStore(File(dir, "macs.json"))
        assertEquals(emptyList(), macs.load())
        val mac = PairedMac(name = "Mac", hosts = listOf("mac.local"), sshPort = 22, user = "max", hostKey = "ssh-ed25519 AAAA", hostKeyFingerprint = "SHA256:x")
        macs.save(listOf(mac))
        assertEquals(listOf(mac), FileMacStore(File(dir, "macs.json")).load())
        assertEquals("rw-------", mode(File(dir, "macs.json")))

        val settings = FileSettingsStore(File(dir, "settings.json"))
        settings.update { it.copy(deviceName = "Max’ PC", requireUnlock = true) }
        assertEquals("Max’ PC", FileSettingsStore(File(dir, "settings.json")).settings.first().deviceName)

        val secrets = DesktopSecretStore(TestSealer(), File(dir, "secrets.json"))
        secrets.put("screen-login-1", "geheim".toByteArray())
        assertContentEquals("geheim".toByteArray(), secrets.get("screen-login-1"))
        assertFalse(File(dir, "secrets.json").readText().contains("geheim"), "sealed on disk")
        secrets.put("screen-login-1", null)
        assertNull(secrets.get("screen-login-1"))

        val prefs = Prefs(File(dir, "terminal.json"))
        prefs.set("fontSize", 15)
        assertEquals(15, Prefs(File(dir, "terminal.json")).int("fontSize", 13))
    }

    @Test fun everyStringResolvesInBothLanguages() {
        for (locale in listOf(Locale.ENGLISH, Locale.GERMAN)) {
            DesktopStrings.use(locale)
            for ((id, name) in R.names) {
                if (name.startsWith("drawable/") || name.startsWith("raw/")) continue
                // German overrides of Termux's own strings (its library has the English ones): Android only.
                if (name in setOf("paste_text", "copy_text", "text_selection_more")) continue
                val text = if (id >= 0x7f020000) DesktopStrings.quantityText(id, 2, 2) else DesktopStrings.text(id)
                assertNotEquals(name, text, "$name has a text in $locale")
            }
        }
        DesktopStrings.use(Locale.GERMAN)
        assertEquals("Dieser Computer", DesktopStrings.text(R.string.settings_this_phone), "the desktop's wording wins")
        assertEquals("Verbunden mit Max’s Mac", DesktopStrings.text(R.string.desktop_tray_connected, "Max’s Mac"))
        assertEquals("1 Anfrage wartet", DesktopStrings.quantityText(R.plurals.desktop_tray_waiting, 1, 1))
        assertEquals("3 Anfragen warten", DesktopStrings.quantityText(R.plurals.desktop_tray_waiting, 3, 3))
        DesktopStrings.use(Locale.ENGLISH)
        assertEquals("Don't Allow", DesktopStrings.text(R.string.dont_allow), "Android's escapes are undone")
        assertTrue(DesktopStrings.rawText(R.raw.license_apache2).contains("Apache License"))
        assertTrue(DesktopStrings.resourceBytes(R.drawable.aos_icon_art).size > 1000)
    }

    @Test fun germanDesktopTextsHaveNoDashes() {
        val de = File(System.getProperty("user.dir"), "src/main/res/values-de").listFiles()!!.joinToString("\n") { it.readText() }
        assertFalse(Regex(" [–—-] ").containsMatchIn(de), "no dashes as punctuation")
    }

    @Test fun relativeTimes() {
        DesktopStrings.use(Locale.GERMAN)
        val now = 1_000_000_000_000L
        assertEquals("vor 4 Min.", DesktopStrings.relativeTime(now - 4 * 60_000, now))
        assertEquals("in 2 Std.", DesktopStrings.relativeTime(now + 2 * 3_600_000 + 1000, now))
        assertEquals("gestern", DesktopStrings.relativeTime(now - 30 * 3_600_000L, now))
        DesktopStrings.use(Locale.ENGLISH)
        assertEquals("4 min. ago", DesktopStrings.relativeTime(now - 4 * 60_000, now))
    }

    @Test fun winRtParameterizedIids() {
        // Known from Windows' headers: IAsyncOperation<boolean>.
        assertEquals("{CDB5EFB3-5788-509D-9BE1-71CCB8A3362A}", WinHello.parameterizedIid("pinterface({9fc2b0bb-e446-44e2-aa61-9cab8f636af2};b1)"))
        assertTrue(WinHello.asyncOperationIid.matches(Regex("\\{[0-9A-F-]{36}}")))
    }

    @Test fun cngPublicBlobBecomesX963() {
        val pair = P256.generate()
        val x963 = P256.x963(pair.public)
        val blob = byteArrayOf(0x45, 0x43, 0x53, 0x31, 32, 0, 0, 0) + x963.copyOfRange(1, 65)
        assertContentEquals(x963, CngKey.eccPublicBlobToX963(blob))
        assertFailsWith<IllegalArgumentException> { CngKey.eccPublicBlobToX963(ByteArray(8)) }
    }

    @Test fun keyboardMapsToTheMac() {
        val none = emptySet<ModifierKey>()
        val a = DesktopKeys.macKey(Awt.VK_A, none, 'a'.code)!!
        assertEquals(0, a.keyCode)
        assertEquals('a'.code, a.keysym)
        assertEquals('A'.code, DesktopKeys.macKey(Awt.VK_A, setOf(ModifierKey.SHIFT), 'A'.code)!!.keysym)
        // Control: the key's own character (AWT reports a control character).
        assertEquals('c'.code, DesktopKeys.macKey(Awt.VK_C, setOf(ModifierKey.CONTROL), 3)!!.keysym)
        assertEquals('C'.code, DesktopKeys.macKey(Awt.VK_C, setOf(ModifierKey.COMMAND, ModifierKey.SHIFT), 0)!!.keysym)
        assertEquals(Keysym.RETURN, DesktopKeys.macKey(Awt.VK_ENTER, none, '\n'.code)!!.keysym)
        assertEquals(36, DesktopKeys.macKey(Awt.VK_ENTER, none, '\n'.code)!!.keyCode)
        assertEquals(Keysym.function(5), DesktopKeys.macKey(Awt.VK_F5, none, 0xffff)!!.keysym)
        assertEquals(Keysym.COMMAND_LEFT, DesktopKeys.macKey(Awt.VK_WINDOWS, none, 0xffff)!!.keysym)
        assertEquals('ü'.code, DesktopKeys.macKey(Awt.VK_OPEN_BRACKET, none, 'ü'.code)!!.keysym, "what the layout types")
        assertNull(DesktopKeys.macKey(Awt.VK_UNDEFINED, none, 0xffff))
    }

    @Test fun networkPathAndTailnetAddresses() {
        val path = PollingNetworkMonitor.read()
        assertEquals(path.satisfied, path.interfaceId != null)
        assertTrue(PollingNetworkMonitor.isTailnet(java.net.InetAddress.getByName("100.101.7.12")))
        assertFalse(PollingNetworkMonitor.isTailnet(java.net.InetAddress.getByName("192.168.178.24")))
    }

    @Test fun aSecondStartHandsItsLinkToTheFirst() {
        val dir = tempDir()
        val first = SingleInstance(dir)
        assertFalse(first.handOver("show"), "nobody listens yet")
        val got = java.util.concurrent.LinkedBlockingQueue<String>()
        first.listen { got += it }
        assertTrue(SingleInstance(dir).handOver("aos-pair://v1?x=1"))
        assertEquals("aos-pair://v1?x=1", got.poll(5, java.util.concurrent.TimeUnit.SECONDS))
        // Without the token (another program on 127.0.0.1) nothing arrives.
        val port = File(dir, "instance.port").readText().split(' ')[0].toInt()
        java.net.Socket("127.0.0.1", port).use { it.getOutputStream().write("wrong\naos-pair://evil\n".toByteArray()) }
        assertNull(got.poll(500, java.util.concurrent.TimeUnit.MILLISECONDS))
        first.close()
    }
}
