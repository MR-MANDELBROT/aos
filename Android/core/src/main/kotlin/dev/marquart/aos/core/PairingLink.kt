package dev.marquart.aos.core

import java.io.ByteArrayOutputStream

/** How the phone reaches the Mac on the go (`w` in the pairing link; AOSKit `ReachWay`). */
enum class ReachWay(val raw: String) {
    /** The person's own Tailscale app on the Mac and on the phone. */
    TAILSCALE_APP("app"),

    /** aOS's own Tailscale node on the Mac and in the app (the "aos" way; `TailnetDialer` in the app). */
    AOS_TAILSCALE("aos"),

    /** Only on the same network. */
    LOCAL_NETWORK("lan");

    companion object {
        /** An unknown value counts as none. */
        fun from(raw: String?): ReachWay? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * The pairing code that aOS on the Mac shows as a QR code (Docs/COMPANION.md, "Pairing"):
 *
 *     aos-pair://v1?n=<Mac name>&h=<host1>,<host2>&p=<pairing port>&s=22&u=<user>&k=<host key fingerprint>&c=<code>
 *         [&w=<way>&t=<tailnet host1>,<tailnet host2>&tn=<tailnet name>]
 *
 * All values are percent-encoded. `c` is a secret: it only lives in the QR code and proves to the Mac that this phone
 * saw the code; it is never sent.
 */
data class PairingLink(
    val macName: String,
    /** Names and addresses to try in order: `<name>.local`, IPv4 addresses, tailnet hosts. */
    val hosts: List<String>,
    val pairingPort: Int,
    val sshPort: Int = 22,
    val user: String,
    /** `SHA256:...` of the Mac's ed25519 SSH host key (OpenSSH form, no padding). */
    val hostKeyFingerprint: String,
    /** The 16 random bytes of `c`. */
    val code: ByteArray,
    /** How the phone reaches the Mac on the go (`w`); null from a Mac before that choice existed. */
    val way: ReachWay? = null,
    /** The Mac's tailnet addresses and MagicDNS names (`t`), IPv4 first. */
    val tailnetHosts: List<String> = emptyList(),
    /** The tailnet's name (`tn`): sign in to the same one on the phone. */
    val tailnetName: String? = null,
) {
    sealed class ParseError(message: String) : Exception(message) {
        data object NotAPairingLink : ParseError("not a pairing link")

        /** A link of a newer version (v2, v3, ...): "update the app". */
        data object NewerVersion : ParseError("a newer pairing link: update the app")
        data class Missing(val field: String) : ParseError("missing $field")
        data class Invalid(val field: String) : ParseError("invalid $field")
    }

    override fun equals(other: Any?): Boolean = other is PairingLink && macName == other.macName &&
        hosts == other.hosts && pairingPort == other.pairingPort && sshPort == other.sshPort && user == other.user &&
        hostKeyFingerprint == other.hostKeyFingerprint && code.contentEquals(other.code) && way == other.way &&
        tailnetHosts == other.tailnetHosts && tailnetName == other.tailnetName

    override fun hashCode(): Int = listOf(macName, hosts, pairingPort, user, hostKeyFingerprint).hashCode()

    override fun toString(): String = "PairingLink(macName=$macName, hosts=$hosts, pairingPort=$pairingPort, " +
        "sshPort=$sshPort, user=$user, hostKeyFingerprint=$hostKeyFingerprint, code=<hidden>, way=$way, " +
        "tailnetHosts=$tailnetHosts, tailnetName=$tailnetName)"

    /** The link as aOS on the Mac writes it (tests, demo). */
    val url: String
        get() {
            val items = mutableListOf(
                "n=" + enc(macName),
                "h=" + hosts.joinToString(",", transform = ::enc),
                "p=$pairingPort",
                "s=$sshPort",
                "u=" + enc(user),
                "k=" + enc(hostKeyFingerprint),
                "c=" + enc(Bytes.base64UrlEncode(code)),
            )
            way?.let { items += "w=" + it.raw }
            if (tailnetHosts.isNotEmpty()) items += "t=" + tailnetHosts.joinToString(",", transform = ::enc)
            tailnetName?.let { items += "tn=" + enc(it) }
            return "$SCHEME://v1?" + items.joinToString("&")
        }

    companion object {
        const val SCHEME = "aos-pair"

        /** Parses a pasted or scanned link. Surrounding white space is ignored. */
        fun parse(text: String): PairingLink {
            val trimmed = text.trim()
            val schemeEnd = trimmed.indexOf("://")
            if (schemeEnd <= 0 || !trimmed.substring(0, schemeEnd).equals(SCHEME, ignoreCase = true)) {
                throw ParseError.NotAPairingLink
            }
            var rest = trimmed.substring(schemeEnd + 3)
            rest = rest.substringBefore('#')
            // aos-pair://v1?... puts the version in the host position.
            val hostEnd = rest.indexOfFirst { it == '?' || it == '/' }.let { if (it < 0) rest.length else it }
            val version = rest.substring(0, hostEnd).lowercase()
            if (version.isEmpty()) throw ParseError.NotAPairingLink
            if (version != "v1") {
                if (version.startsWith("v") && version.drop(1).toIntOrNull() != null) throw ParseError.NewerVersion
                throw ParseError.NotAPairingLink
            }
            val query = rest.substring(hostEnd).substringAfter('?', "")
            val values = LinkedHashMap<String, String>()
            for (item in query.split('&')) {
                if (item.isEmpty()) continue
                val name = percentDecode(item.substringBefore('=')) ?: throw ParseError.NotAPairingLink
                val value = if (item.contains('=')) percentDecode(item.substringAfter('=')) ?: throw ParseError.NotAPairingLink else ""
                if (name !in values) values[name] = value
            }
            fun required(name: String): String {
                val value = values[name]?.trim(' ', '\t')
                if (value.isNullOrEmpty()) throw ParseError.Missing(name)
                return value
            }

            val seen = HashSet<String>()
            val hosts = required("h").split(',').map(::normalizedHost).filter { it.isNotEmpty() }
                .filter { seen.add(it.lowercase()) }
            if (hosts.isEmpty()) throw ParseError.Missing("h")
            if (!hosts.all(::isPlausibleHost)) throw ParseError.Invalid("h")

            val pairingPort = required("p").toIntOrNull()?.takeIf { it in 1..65535 } ?: throw ParseError.Invalid("p")
            val sshPort = values["s"]?.takeIf { it.isNotEmpty() }?.let { s ->
                s.toIntOrNull()?.takeIf { it in 1..65535 } ?: throw ParseError.Invalid("s")
            } ?: 22

            val user = required("u")
            if (user.any { it.isWhitespace() || it.isISOControl() }) throw ParseError.Invalid("u")

            val fingerprint = SSHKeyFormat.normalizedFingerprint(required("k")) ?: throw ParseError.Invalid("k")
            val code = Bytes.base64UrlDecode(required("c"))?.takeIf { it.size == 16 } ?: throw ParseError.Invalid("c")

            val name = (values["n"] ?: "").trim()
            val macName = if (name.isEmpty()) hosts[0] else prefixCodePoints(name, 80)

            // On the go (optional; an unknown way counts as none).
            val way = ReachWay.from(values["w"]?.trim()?.lowercase())
            val seenTailnet = HashSet<String>()
            val tailnetHosts = (values["t"] ?: "").split(',').map(::normalizedHost)
                .filter { it.isNotEmpty() && isPlausibleHost(it) && seenTailnet.add(it.lowercase()) }
            val tailnet = (values["tn"] ?: "").trim()
            val tailnetName = tailnet.takeUnless {
                it.isEmpty() || it.codePointCount(0, it.length) > 128 || it.any(Char::isISOControl)
            }
            return PairingLink(macName, hosts, pairingPort, sshPort, user, fingerprint, code, way, tailnetHosts, tailnetName)
        }

        /** Whether this text is meant as a pairing link (by its scheme), even one this app can't read. */
        fun looksLikeOne(text: String): Boolean = text.trim().lowercase().startsWith("$SCHEME:")

        private fun normalizedHost(raw: String): String {
            var host = raw.trim(' ', '\t')
            // "[fe80::1]" -> "fe80::1"
            if (host.startsWith("[") && host.endsWith("]") && host.length >= 2) host = host.substring(1, host.length - 1)
            if (host.endsWith(".") && host.length > 1) host = host.dropLast(1)
            return host
        }

        private fun isPlausibleHost(host: String): Boolean {
            if (host.length > 253) return false
            return host.none { it.isWhitespace() || it.isISOControl() || it in "/?#@\\\"'<>" }
        }

        private fun prefixCodePoints(text: String, count: Int): String {
            if (text.codePointCount(0, text.length) <= count) return text
            return text.substring(0, text.offsetByCodePoints(0, count))
        }

        /** Percent-decoding as URLComponents does it: `+` stays a plus. Null for a broken escape. */
        fun percentDecode(text: String): String? {
            if (!text.contains('%')) return text
            val out = ByteArrayOutputStream()
            var i = 0
            while (i < text.length) {
                if (text[i] == '%') {
                    if (i + 3 > text.length) return null
                    val byte = text.substring(i + 1, i + 3).toIntOrNull(16) ?: return null
                    out.write(byte)
                    i += 3
                } else {
                    val codePoint = text.codePointAt(i)
                    out.write(Bytes.utf8(String(Character.toChars(codePoint))))
                    i += Character.charCount(codePoint)
                }
            }
            return out.toByteArray().toString(Charsets.UTF_8)
        }

        private const val UNRESERVED = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"

        /** Percent-encodes everything that isn't unreserved, so `+` and `/` in base64 values survive any decoder. */
        fun enc(text: String): String = buildString {
            for (b in Bytes.utf8(text)) {
                val c = (b.toInt() and 0xFF).toChar()
                if (c in UNRESERVED && b >= 0) append(c) else append('%').append("%02X".format(b.toInt() and 0xFF))
            }
        }
    }
}
