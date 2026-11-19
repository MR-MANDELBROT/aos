package dev.marquart.aos.terminal

import dev.marquart.aos.core.MacTermSession
import dev.marquart.aos.core.TermAttach
import dev.marquart.aos.model.AppModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.time.Instant

/** The terminal sessions on the paired Mac (`aos-companion term list`). */
class MacSessionList {
    private val _sessions = MutableStateFlow<List<MacTermSession>>(emptyList())
    private val _loaded = MutableStateFlow(false)
    val sessions: StateFlow<List<MacTermSession>> = _sessions.asStateFlow()

    /** The Mac sent its list at least once (an empty list then means: none). */
    val loaded: StateFlow<Boolean> = _loaded.asStateFlow()

    suspend fun load(model: AppModel) {
        val connection = model.connection.value ?: return
        val ssh = connection.ssh.value ?: return
        if (!ssh.isActive) return
        val list = try {
            connection.termSessions()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        } ?: return
        _sessions.value = TermAttach.ordered(list)
        _loaded.value = true
    }

    /** Ends a session (the terminal's own through the terminal, which then says so). */
    suspend fun end(session: MacTermSession, model: AppModel, terminal: MacTerminal?) {
        if (terminal != null && terminal.holderId.value == session.id) {
            terminal.endSession()
        } else {
            try {
                model.connection.value?.endTermSession(session.id)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
        _sessions.value = _sessions.value.filter { it.id != session.id }
        if (model.demo != null) return
        delay(400)
        load(model)
    }

    /** The name of a session in menus and titles: its title, or the program and the folder. */
    fun name(id: String?, home: String, place: (MacTermSession) -> String): String? {
        val session = _sessions.value.firstOrNull { it.id == id } ?: return null
        return session.title ?: place(session)
    }

    /** Claude Code open on this phone, a shell nobody has open, one in a terminal on the Mac (the demo). */
    fun showDemo(phoneId: String?) {
        val now = Instant.now()
        _sessions.value = TermAttach.ordered(listOf(
            MacTermSession("3fa9c1d2", attached = true, since = now.minusSeconds(600), created = now.minusSeconds(7200),
                from = "ssh 192.168.178.31", client = phoneId, command = "claude", cwd = "/Users/max/Developer/aos"),
            MacTermSession("7b2e90aa", attached = false, since = now.minusSeconds(3 * 3600), created = now.minusSeconds(5 * 3600),
                command = "zsh", cwd = "/Users/max"),
            MacTermSession("c41d07e5", attached = true, since = now.minusSeconds(1200), created = now.minusSeconds(1800),
                from = "local", command = "htop", cwd = "/Users/max"),
        ))
        _loaded.value = true
    }
}
