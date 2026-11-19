package dev.marquart.aos.desktop.system

import dev.marquart.aos.R
import dev.marquart.aos.core.HelpRequest
import dev.marquart.aos.core.SignInRequest
import dev.marquart.aos.desktop.AppIcon
import dev.marquart.aos.desktop.DesktopStrings
import dev.marquart.aos.desktop.Os
import dev.marquart.aos.model.AppModel
import dev.marquart.aos.ui.AosUi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlin.concurrent.thread

/**
 * Requests that arrive while the window isn't shown (closed to the tray, minimized): a desktop notification each
 * (Windows: the tray's toast; Linux: notify-send, the desktop's notification server). A click opens the window with
 * the request, as Android's notification does (ui/notify/RequestNotifier.kt there).
 */
class Notifier(private val model: AppModel, private val settings: DesktopSettings) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val seen = mutableSetOf<String>()
    private var tray: TrayHandle? = null
    private var isShown: () -> Boolean = { true }
    private var open: (String) -> Unit = {}

    fun start(tray: TrayHandle, isShown: () -> Boolean, open: (String) -> Unit) {
        this.tray = tray
        this.isShown = isShown
        this.open = open
        scope.launch {
            combine(model.questions, model.helpRequests) { q, h -> q to h }.collect { (questions, help) ->
                val current = questions.map { it.id }.toSet() + help.map { it.id }
                for (q in questions) post(q.id) { text(q) }
                for (h in help) post(h.id) { text(h) }
                seen.retainAll(current)
            }
        }
    }

    /** The window came to the front: what is waiting is on screen there. */
    fun clear() {
        tray?.lastRequest = null
    }

    private inline fun post(id: String, make: () -> Pair<String, String>) {
        if (id in seen) return
        seen += id
        if (isShown() || !settings.notifications.value) return
        val (title, text) = make()
        show(id, title, text)
    }

    private fun show(id: String, title: String, text: String) {
        if (Os.isLinux && Os.commandExists("notify-send")) {
            thread(isDaemon = true, name = "aos-notify") {
                runCatching {
                    // --wait with an action: notify-send prints the action when the notification is clicked.
                    val process = ProcessBuilder("notify-send", "--app-name=aOS", "--icon=${AppIcon.file.path}", "--urgency=critical",
                        "--action=default=" + DesktopStrings.text(R.string.desktop_tray_open), "--wait", title, text)
                        .redirectErrorStream(true).start()
                    val out = process.inputStream.bufferedReader().readText().trim()
                    if (out == "default") scope.launch { open(id) }
                }
            }
        } else {
            tray?.lastRequest = id
            tray?.notify(title, text)
        }
    }

    /** Opens the request in the window (from a notification). */
    fun openRequest(id: String?, ui: AosUi) {
        val requestId = id ?: tray?.lastRequest ?: return
        model.questions.value.firstOrNull { it.id == requestId }?.let {
            model.present(it)
            model.selectTab(AppModel.Tab.OVERVIEW)
            return
        }
        model.helpRequests.value.firstOrNull { it.id == requestId }?.let { model.showHelp(it) }
    }

    private fun text(question: AppModel.Question): Pair<String, String> = when (question) {
        is AppModel.Question.SignIn -> {
            val r = question.request
            val agent = r.agent.ifEmpty { DesktopStrings.text(R.string.your_agent) }
            DesktopStrings.text(if (r.field == SignInRequest.Field.CODE) R.string.request_asks_code else R.string.request_asks_sign_in, agent) to
                listOf(r.host, r.purpose).filter { it.isNotEmpty() }.joinToString(": ")
        }
        is AppModel.Question.Approval -> {
            val r = question.request
            val agent = r.agent.ifEmpty { DesktopStrings.text(R.string.your_agent) }
            DesktopStrings.text(R.string.request_wants_workspace, agent) to r.purpose
        }
    }

    private fun text(help: HelpRequest): Pair<String, String> {
        val agent = help.agent.ifEmpty { DesktopStrings.text(R.string.your_agent) }
        return DesktopStrings.text(R.string.request_asks_help, agent) to help.purpose
    }
}
