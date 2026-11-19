package dev.marquart.aos.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.ByteArrayOutputStream
import java.time.Instant

// The terminal on the paired Mac runs in a session that outlives the connection (Docs/COMPANION.md, "Terminal
// sessions"): the phone's SSH channel runs `aos-companion term attach` in a pseudo terminal. The Mac's side tells the
// phone where the output starts with a note (`ESC ] 7730 ; <JSON> BEL`, AOSKit `TermMarker`); the phone takes the notes
// out before its terminal sees them and counts the output bytes after the start: when it attaches again it asks for
// what comes after that count, and gets exactly what it missed. iOS Sources/Terminal/TerminalAttach.swift.

/** A note from `term attach`. */
sealed class TermNote {
    /** The output that follows starts at `from`. `reset`: the terminal starts afresh (it gets the last part of the
     *  output, after `prefix` with the modes in effect there). `isNew`: a session that was just started; `gone`: the one
     *  asked for had ended, this is a new one. */
    data class Start(val id: String, val from: Long, val reset: Boolean, val prefix: ByteArray, val isNew: Boolean,
                     val gone: String?) : TermNote() {
        override fun equals(other: Any?) = other is Start && id == other.id && from == other.from && reset == other.reset &&
            prefix.contentEquals(other.prefix) && isNew == other.isNew && gone == other.gone
        override fun hashCode() = listOf(id, from, reset, isNew, gone).hashCode()
    }

    /** Over for this terminal: `exited` (the shell ended; `status`), `ended` (someone ended it), `taken` (another
     *  device attached), `replaced` (this phone attached again: this was its old connection), `lost`. */
    data class End(val why: String, val status: Int?) : TermNote()

    companion object {
        fun parse(json: ByteArray): TermNote? {
            val o = Json.parseObject(json) ?: return null
            return when (o["t"].str) {
                "start" -> {
                    val id = o["id"].str?.takeIf(TermAttach::isId) ?: return null
                    val fromText = (o["from"] as? JsonPrimitive)?.takeIf { !it.isString }?.content ?: return null
                    val from = fromText.toULongOrNull()?.toLong() ?: o["from"].long ?: return null
                    Start(id, from, o["reset"].bool ?: true, o["prefix"].str?.let(Bytes::base64Decode) ?: ByteArray(0),
                        o["new"].bool ?: false, o["gone"].str)
                }
                "end" -> End(o["why"].str ?: "ended", o["status"].int)
                else -> null
            }
        }
    }
}

/** Takes the notes out of the terminal's output. Notes may arrive split over several chunks. Not thread-safe. */
class TermNoteFilter {
    sealed class Piece {
        class Bytes(val data: ByteArray) : Piece() {
            override fun equals(other: Any?) = other is Bytes && data.contentEquals(other.data)
            override fun hashCode() = data.contentHashCode()
            override fun toString() = "Bytes(${data.toString(Charsets.UTF_8)})"
        }

        data class Note(val note: TermNote) : Piece()
    }

    private var carry = ByteArray(0)

    fun feed(chunk: ByteArray): List<Piece> {
        val input = if (carry.isEmpty()) chunk else carry + chunk
        carry = ByteArray(0)
        val pieces = mutableListOf<Piece>()
        var plainStart = 0
        fun plain(end: Int) {
            if (end > plainStart) pieces += Piece.Bytes(input.copyOfRange(plainStart, end))
        }
        var k = 0
        while (k < input.size) {
            val esc = indexOf(input, 0x1b, k)
            if (esc < 0) break
            val rest = input.size - esc
            var matched = 0
            while (matched < INTRODUCER.size && matched < rest && input[esc + matched] == INTRODUCER[matched]) matched++
            if (matched < INTRODUCER.size) {
                // The start of an introducer at the end of the chunk waits for the next one.
                if (matched == rest) {
                    plain(esc)
                    carry = input.copyOfRange(esc, input.size)
                    return pieces
                }
                k = esc + 1
                continue
            }
            val body = esc + INTRODUCER.size
            val bell = indexOf(input, 0x07, body)
            if (bell < 0) {
                if (rest > MAX_NOTE) {
                    k = esc + 1
                    continue
                }
                plain(esc)
                carry = input.copyOfRange(esc, input.size)
                return pieces
            }
            val note = TermNote.parse(input.copyOfRange(body, bell))
            if (note != null) {
                plain(esc)
                pieces += Piece.Note(note)
                plainStart = bell + 1
            }
            k = bell + 1
        }
        plain(input.size)
        return pieces
    }

    private fun indexOf(data: ByteArray, byte: Int, from: Int): Int {
        for (i in from until data.size) if (data[i] == byte.toByte()) return i
        return -1
    }

    companion object {
        val INTRODUCER: ByteArray = byteArrayOf(0x1b, 0x5d) + "7730;".toByteArray(Charsets.US_ASCII)

        /** A note longer than this isn't one (the bytes go to the terminal as they are). */
        const val MAX_NOTE = 64 * 1024

        /** A note as the Mac writes it (tests, the in-process Mac). */
        fun note(json: String): ByteArray {
            val out = ByteArrayOutputStream()
            out.write(INTRODUCER)
            out.write(Bytes.utf8(json))
            out.write(0x07)
            return out.toByteArray()
        }
    }
}

/** The commands the phone runs on the Mac (in the login shell sshd starts them with, so the path is quoted). */
object TermAttach {
    fun isId(text: String): Boolean = text.length == 8 && text.all { it in '0'..'9' || it in 'a'..'f' }

    /** In a pseudo terminal: attach to `id` (only what came after `have`), or start a new session. `client`: this
     *  phone (its phone id): attaching again replaces its own old connection without a word. */
    fun attach(companion: String, id: String?, have: Long?, client: String? = null): String {
        var command = CompanionCommand.shellQuoted(companion) + " term attach"
        if (id != null && isId(id)) {
            command += " --id $id"
            if (have != null && have >= 0) command += " --have $have"
        }
        if (client != null && isClientId(client)) command += " --client $client"
        return command
    }

    /** What the Mac takes as a device id (AOSKit `TermHello.isClientID`): nothing the shell would read differently. */
    fun isClientId(text: String): Boolean =
        text.length in 1..64 && text.all { it.code < 128 && (it.isLetterOrDigit() || it in ".-_") }

    fun list(companion: String): String = CompanionCommand.shellQuoted(companion) + " term list --json"

    fun end(companion: String, id: String): String? =
        if (isId(id)) CompanionCommand.shellQuoted(companion) + " term end $id" else null

    /** `term list --json`: the sessions on the Mac. */
    fun sessions(list: ByteArray): List<MacTermSession>? {
        val o = Json.parseObject(list) ?: return null
        val sessions = o["sessions"].arr ?: return null
        return sessions.mapNotNull { it.obj?.let(MacTermSession::from) }
    }

    /** The order of the list: the oldest first, a new session at the end (rows don't move when they change). */
    fun ordered(sessions: List<MacTermSession>): List<MacTermSession> =
        sessions.sortedWith(compareBy<MacTermSession> { it.created ?: Instant.MAX }.thenBy { it.id })
}

/** A terminal session on the Mac, as `term list` shows it. */
data class MacTermSession(
    val id: String,
    val attached: Boolean,
    /** When the client attached, or since when none is. */
    val since: Instant? = null,
    val created: Instant? = null,
    val lastOutput: Instant? = null,
    /** Who is attached ("ssh 192.168.178.31"). */
    val from: String? = null,
    /** The attached device's id (this phone's phone id when it is this phone; null from an older aOS). */
    val client: String? = null,
    /** The program in the foreground and its folder. */
    val command: String? = null,
    val cwd: String? = null,
    val title: String? = null,
) {
    sealed class Holder {
        /** This phone (its terminal shows it, or an older connection of this phone is still attached). */
        data object Here : Holder()

        /** Another device, or a terminal on the Mac. */
        data class Elsewhere(val from: String?) : Holder()
        data object Nobody : Holder()
    }

    /** Who has it open, as this phone sees it. Never "another device" for this phone's own connection. */
    fun holder(shown: String?, phoneId: String?, last: String?): Holder {
        if (id == shown) return Holder.Here
        if (!attached) return Holder.Nobody
        if (client != null) return if (client == phoneId) Holder.Here else Holder.Elsewhere(from)
        return if (id == last) Holder.Here else Holder.Elsewhere(from)
    }

    /** "zsh in ~/Developer/aos", from the Mac user's home folder. */
    fun place(home: String?): String {
        var folder = cwd ?: ""
        if (!home.isNullOrEmpty() && folder == home) folder = "~"
        else if (!home.isNullOrEmpty() && folder.startsWith("$home/")) folder = "~" + folder.substring(home.length)
        val program = command ?: "shell"
        return if (folder.isEmpty()) program else "$program in $folder"
    }

    companion object {
        fun from(o: JsonObject): MacTermSession? {
            val id = o["id"].str?.takeIf(TermAttach::isId) ?: return null
            fun date(key: String) = o[key].str?.let(Iso8601::parse)
            return MacTermSession(id, o["attached"].bool ?: false, date("since"), date("created"), date("lastOutput"),
                o["from"].str, o["client"].str, o["command"].str, o["cwd"].str, o["title"].str)
        }
    }
}

/** `term end <id>` answered: `{"ok":true}` or `{"ok":false,"gone":true}`. */
fun termEndResult(data: ByteArray): Boolean? = Json.parseObject(data)?.get("ok").bool

