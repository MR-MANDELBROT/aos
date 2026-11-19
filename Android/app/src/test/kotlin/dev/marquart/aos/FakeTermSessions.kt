package dev.marquart.aos

import dev.marquart.aos.core.CompanionCommand
import dev.marquart.aos.core.TermNoteFilter
import java.util.UUID

/**
 * The Mac's terminal sessions as the test SSH server plays them (`aos-companion term attach|list|end`, AOSKit
 * TermHolder; iOS Tests/Support/FakeTermSessions.swift): each session keeps all its output with offsets, one channel at
 * a time is attached, a channel that attaches with `--have N` gets what came after N, one without gets everything
 * afresh. A new attach takes the session over: the one before hears "replaced" when both named the same device
 * (`--client`), "taken" otherwise. Typed input comes back as output (an echo); "exit\r" ends the shell, "drop\r" drops
 * the connection (the channel closes without a word, as when the network goes) and the session writes "while away"
 * meanwhile.
 *
 * `attachFails` plays an aOS that can't hold sessions or refuses: `term attach` exits with that status and text on
 * stderr before any note (2: an aOS without `term`, 127: not where it was paired, 1: "at most 16 sessions").
 */
class FakeTermSessions {
    class Attached(val write: (ByteArray) -> Unit, val error: (ByteArray) -> Unit, val close: (status: Int?) -> Unit) {
        val id: UUID = UUID.randomUUID()
    }

    private class Session(val id: String) {
        var output = ByteArray(0)
        var attached: Attached? = null

        /** The device the attached channel named. */
        var client: String? = null
    }

    private val lock = Any()
    private val sessions = LinkedHashMap<String, Session>()
    private var counter = 0
    private val requests = mutableListOf<String>()
    private val attachClients = mutableListOf<String?>()

    /** `term attach` exits with this status (and `failText` on stderr) instead of attaching. */
    @Volatile var attachFails: Int? = null
    @Volatile var failText: String = ""

    private val typed = java.io.ByteArrayOutputStream()

    /** Everything typed into any session, in order. */
    val received: ByteArray get() = synchronized(lock) { typed.toByteArray() }

    /** What the phone asked for, in order ("attach new", "attach 0000aa01 have 12", "list", "end 0000aa01"). */
    val log: List<String> get() = synchronized(lock) { requests.toList() }

    /** The device each attach named, in order (null: none). */
    val clients: List<String?> get() = synchronized(lock) { attachClients.toList() }

    /** Handles an exec command of the companion's `term`; false if it isn't one. */
    fun handle(command: String, companion: String, attached: Attached): Boolean {
        val prefix = CompanionCommand.shellQuoted(companion) + " term "
        if (!command.startsWith(prefix)) return false
        val words = command.substring(prefix.length).split(" ").filter { it.isNotEmpty() }
        fun value(name: String): String? = words.indexOf(name).takeIf { it >= 0 && it + 1 < words.size }?.let { words[it + 1] }
        when (words.firstOrNull()) {
            "attach" -> {
                attachFails?.let { status ->
                    synchronized(lock) { requests += "attach refused" }
                    if (failText.isNotEmpty()) attached.error(failText.toByteArray())
                    attached.close(status)
                    return true
                }
                attach(value("--id"), value("--have")?.toLongOrNull(), value("--client"), attached)
            }
            "list" -> {
                val list = synchronized(lock) {
                    requests += "list"
                    sessions.values.joinToString(",") { s ->
                        val client = if (s.attached != null && s.client != null) ""","client":"${s.client}"""" else ""
                        """{"attached":${s.attached != null}$client,"command":"zsh","cwd":"/Users/max","id":"${s.id}"}"""
                    }
                }
                attached.write("""{"sessions":[$list]}""".toByteArray() + 0x0a)
                attached.close(0)
            }
            "end" -> {
                val id = words.getOrElse(1) { "" }
                val session = synchronized(lock) {
                    requests += "end $id"
                    sessions.remove(id)
                }
                session?.attached?.let { other ->
                    other.write(end("ended"))
                    other.close(0)
                }
                attached.write((if (session == null) "{\"ok\":false,\"gone\":true}\n" else "{\"ok\":true}\n").toByteArray())
                attached.close(0)
            }
            else -> attached.close(2)
        }
        return true
    }

    private fun attach(id: String?, have: Long?, client: String?, channel: Attached) {
        var previous: Attached? = null
        var same = false
        var isNew = false
        val session: Session
        synchronized(lock) {
            attachClients += client
            val existing = id?.let { sessions[it] }
            if (existing != null) {
                requests += "attach $id" + (have?.let { " have $it" } ?: "")
                previous = existing.attached
                same = client != null && existing.client == client
                existing.attached = channel
                existing.client = client
                session = existing
            } else {
                counter++
                session = Session(String.format("0000aa%02x", counter))
                session.output = "Welcome to the held shell\r\n$ ".toByteArray()
                session.attached = channel
                session.client = client
                sessions[session.id] = session
                requests += "attach new"
                isNew = true
            }
        }
        previous?.let {
            it.write(end(if (same) "replaced" else "taken"))
            it.close(if (same) 5 else 3)
        }
        val (from, rest) = synchronized(lock) {
            val from = if (!isNew && have != null && have <= session.output.size) have else 0L
            from to session.output.copyOfRange(from.toInt(), session.output.size)
        }
        channel.write(start(session.id, from, reset = from == 0L, new = isNew, gone = if (isNew) id else null))
        if (rest.isNotEmpty()) channel.write(rest)
    }

    /** Typed bytes from an attached channel. */
    fun input(data: ByteArray, from: Attached) {
        val text = data.toString(Charsets.UTF_8)
        synchronized(lock) { typed.write(data) }
        val session = synchronized(lock) { sessions.values.firstOrNull { it.attached?.id == from.id } } ?: return
        if (text.contains("drop\r")) {
            synchronized(lock) {
                session.attached = null
                session.output += "drop\r\nwhile away\r\n$ ".toByteArray()
            }
            from.close(null)
            return
        }
        if (text.contains("exit\r")) {
            synchronized(lock) { sessions.remove(session.id) }
            from.write(end("exited", 0))
            from.close(0)
            return
        }
        synchronized(lock) { session.output += data }
        from.write(data)
    }

    companion object {
        /** The notes as AOSKit's TermMarker writes them (sorted keys). */
        fun start(id: String, from: Long, reset: Boolean, new: Boolean, gone: String?): ByteArray = TermNoteFilter.note(
            """{"created":"2026-11-07T10:00:00Z","from":$from,""" + (gone?.let { """"gone":"$it",""" } ?: "") +
                """"id":"$id","new":$new,"prefix":"","reset":$reset,"t":"start"}""")

        fun end(why: String, status: Int? = null): ByteArray =
            TermNoteFilter.note("{" + (status?.let { """"status":$it,""" } ?: "") + """"t":"end","why":"$why"}""")
    }
}
