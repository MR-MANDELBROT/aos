package dev.marquart.aos.companion

import dev.marquart.aos.core.Bytes
import dev.marquart.aos.core.ChatList
import dev.marquart.aos.core.CompanionAuth
import dev.marquart.aos.core.CompanionEvent
import dev.marquart.aos.core.CompanionSignature
import dev.marquart.aos.core.Iso8601
import dev.marquart.aos.core.Json
import dev.marquart.aos.core.LineSplitter
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.MacSideSignature
import dev.marquart.aos.core.P256
import dev.marquart.aos.core.ScreenEndpoint
import dev.marquart.aos.core.ScreenSeal
import dev.marquart.aos.core.ScreenTarget
import dev.marquart.aos.core.WorkspaceState
import dev.marquart.aos.core.WorkspaceStatus
import dev.marquart.aos.core.int
import dev.marquart.aos.core.obj
import dev.marquart.aos.core.str
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant

/**
 * The Mac's side of the companion API in memory: answers requests the way `aos-companion serve` and aOS on the Mac do
 * (Docs/COMPANION.md), checks signatures like `CompanionGate` when it knows a phone, seals the workspace's login, and
 * sends events on demand. Used by the tests (in memory, or behind the in-process SSH server) and for a demo mode.
 * A port of iOS Sources/Companion/MockCompanionServer.swift (the chats keeper and the routines are simplified).
 */
class MockCompanionServer(state: State = State(), private val keepsSecrets: Boolean = false) {
    data class State(
        var macName: String = "Max’s MacBook Pro",
        var aosVersion: String = "0.2.0",
        var workspace: WorkspaceStatus = WorkspaceStatus(WorkspaceState.OPEN, "Rechnungen herunterladen",
            Instant.now().plusSeconds(25 * 60), listOf(WorkspaceStatus.Session(0, "Claude Code", "running"))),
        var screens: MutableMap<ScreenTarget, ScreenEndpoint> = mutableMapOf(
            ScreenTarget.MAC to ScreenEndpoint("127.0.0.1", 5900),
            ScreenTarget.WORKSPACE to ScreenEndpoint("192.168.64.5", 5900, "aos", "demo-only"),
        ),
        /** Requests answered with `ok: false` and this message ... */
        var refuse: MutableMap<String, String> = mutableMapOf(),
        /** ... and this code. */
        var refuseCode: MutableMap<String, String> = mutableMapOf(),
        /** What `mac.status` reports; the actions change it as the Mac would. */
        var macStatus: JsonObject = demoMacStatus(),
        var chats: List<ChatList.Chat> = demoChats(),
        var chatsEnabled: Boolean = true,
        /** The Mac is older and doesn't know the Overview's ops (no features in hello). */
        var oldMac: Boolean = false,
        /** As aOS on the Mac: `workspace.start`/`stop` answer with the state before, then the workspace moves a step per
         *  this many milliseconds, each with its event. Null: at once, in the answer. */
        var workspaceStepMillis: Long? = null,
        /** The phone the Mac knows: with it set, every request must be signed by that phone. */
        var trustedPhone: TrustedSigner? = null,
    )

    /** A phone's signing key as the Mac keeps it. */
    data class TrustedSigner(val phoneId: String, val publicKeyX963: ByteArray)

    /** A request as the server received it. */
    data class Received(val op: String, val fields: JsonObject)

    private val lock = Any()
    private var state = state
    private var subscribed = false
    private val nonces = HashSet<String>()
    private val log = mutableListOf<Received>()
    private var outbound: ((ByteArray) -> Unit)? = null
    private var hangUp: (() -> Unit)? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val received: List<Received> get() = synchronized(lock) { log.toList() }
    val isSubscribed: Boolean get() = synchronized(lock) { subscribed }

    fun update(change: (State) -> Unit) = synchronized(lock) { change(state) }

    // Wiring

    /** A transport for a `CompanionClient`, connected to this server in memory. */
    fun makeTransport(): CompanionTransport {
        val toClient = Channel<ByteArray>(Channel.UNLIMITED)
        attach(write = { toClient.trySend(it) }, hangUp = { toClient.close() })
        return MemoryTransport(this, toClient)
    }

    /** Connects the server to any byte sink (an exec channel's stdout in the SSH tests). Feed what the client sends
     *  into the returned feeder. */
    fun attach(write: (ByteArray) -> Unit, hangUp: () -> Unit): Feeder {
        synchronized(lock) {
            outbound = write
            this.hangUp = hangUp
            subscribed = false
        }
        return Feeder(this)
    }

    /** Splits what the client sends into lines and answers them. */
    class Feeder internal constructor(private val server: MockCompanionServer) {
        private val splitter = LineSplitter()

        fun feed(data: ByteArray) {
            val lines = synchronized(this) { runCatching { splitter.append(data) }.getOrDefault(emptyList()) }
            for (line in lines) if (line.isNotEmpty()) server.handle(line)?.let(server::write)
        }
    }

    /** Sends an event to the client (only after it subscribed, like the Mac). */
    fun emit(event: CompanionEvent) {
        if (!isSubscribed) return
        write(line(event))
    }

    /** Ends the connection from the Mac's side. */
    fun disconnect() {
        val h = synchronized(lock) {
            val h = hangUp
            hangUp = null
            outbound = null
            h
        }
        h?.invoke()
    }

    internal fun write(data: ByteArray) {
        synchronized(lock) { outbound }?.invoke(data)
    }

    // Handling

    /** Handles one request line; returns the answer line (with "\n"). */
    fun handle(line: ByteArray): ByteArray? {
        val o = Json.parseObject(line) ?: return null
        val id = o["id"].int ?: return null
        val op = o["op"].str ?: return null
        val fields = if (!keepsSecrets && o["password"] != null) JsonObject(o + ("password" to JsonPrimitive("•••"))) else o
        val state = synchronized(lock) {
            log += Received(op, fields)
            state.copy()
        }
        state.trustedPhone?.let { trusted ->
            check(op, o, trusted)?.let { (code, message) -> return answer(id, false, "error" to message, "code" to code) }
        }
        if (op == "subscribe") synchronized(lock) { subscribed = true }
        state.refuse[op]?.let { message ->
            return answer(id, false, "error" to message, *listOfNotNull(state.refuseCode[op]?.let { "code" to it }).toTypedArray())
        }
        val action = MacAction.from(op)
        if (action != null && !state.oldMac) {
            val body = mutableMapOf<String, JsonElement>()
            if (action.raw.startsWith("chats.")) {
                chatAction(action, o["text"].str)?.let { (code, message) ->
                    return answer(id, false, "error" to message, *listOfNotNull(code?.let { "code" to it }).toTypedArray())
                }
                body["chats"] = chatsJson()
            }
            body["status"] = macAction(action, o["text"].str)
            if (action == MacAction.SLEEP) {
                body["sleeping"] = JsonPrimitive(true)
                body["after"] = JsonPrimitive(1.5)
            }
            return answerWith(id, body)
        }
        val body = mutableMapOf<String, JsonElement>()
        when (op) {
            "hello" -> {
                body["mac"] = JsonPrimitive(state.macName)
                body["aos"] = JsonPrimitive(state.aosVersion)
                if (!state.oldMac) body["features"] = JsonArray((MacAction.entries.map { it.raw } + "term").map(::JsonPrimitive))
            }
            "status" -> {
                val w = mutableMapOf<String, JsonElement>("state" to JsonPrimitive(state.workspace.state.name),
                    "purpose" to JsonPrimitive(state.workspace.purpose))
                state.workspace.until?.let { w["until"] = JsonPrimitive(Iso8601.format(it)) }
                body["workspace"] = JsonObject(w)
                body["sessions"] = JsonArray(state.workspace.sessions.map {
                    JsonObject(mapOf("title" to JsonPrimitive(it.title), "state" to JsonPrimitive(it.state)))
                })
            }
            "subscribe", "signin.answer", "help.done", "approval.answer", "type" -> Unit
            "display" -> {
                val parts = (o["text"].str ?: "").substringBefore('@').split('x')
                body["width"] = JsonPrimitive(if (parts.size == 2) parts[0].toIntOrNull() ?: 1280 else 1280)
                body["height"] = JsonPrimitive(if (parts.size == 2) parts[1].toIntOrNull() ?: 800 else 800)
                body["lease"] = JsonPrimitive(45)
            }
            "screen" -> {
                val target = ScreenTarget.from(o["target"].str)
                val endpoint = target?.let { state.screens[it] } ?: return answer(id, false, "error" to "no such screen")
                val login = mutableMapOf<String, JsonElement>("host" to JsonPrimitive(endpoint.host), "port" to JsonPrimitive(endpoint.port))
                endpoint.username?.let { login["username"] = JsonPrimitive(it) }
                endpoint.password?.let { login["password"] = JsonPrimitive(it) }
                if (target != ScreenTarget.WORKSPACE) {
                    body.putAll(login)
                } else {
                    // As aOS on the Mac: the workspace's login only sealed to the request's one-time key
                    val key = o["reply"].str?.let(Bytes::base64Decode)
                        ?: return answer(id, false, "code" to "update", "error" to "Update aOS on the iPhone to see the workspace.")
                    val auth = CompanionAuth.from(o["auth"])
                    val sealed = try {
                        ScreenSeal.seal(Bytes.utf8(Json.encode(JsonObject(login))), key, "companion.screen", auth?.key ?: "", auth?.nonce ?: "")
                    } catch (_: Exception) {
                        return answer(id, false, "error" to "bad key")
                    }
                    body["sealed"] = sealed.json
                }
            }
            else -> return answer(id, false, "error" to "unknown op $op")
        }
        return answerWith(id, body)
    }

    private fun answer(id: Int, ok: Boolean, vararg fields: Pair<String, String>): ByteArray =
        Json.line(JsonObject(mapOf("id" to JsonPrimitive(id), "ok" to JsonPrimitive(ok)) + fields.associate { it.first to JsonPrimitive(it.second) }))

    private fun answerWith(id: Int, body: Map<String, JsonElement>): ByteArray =
        Json.line(JsonObject(mapOf("id" to JsonPrimitive(id), "ok" to JsonPrimitive(true)) + body))

    // The Overview

    private fun macAction(action: MacAction, value: String?): JsonObject = synchronized(lock) {
        val status = state.macStatus.toMutableMap()
        fun set(section: String, key: String, v: JsonElement) {
            status[section] = JsonObject((status[section].obj ?: JsonObject(emptyMap())) + (key to v))
        }
        when (action) {
            MacAction.STAY_AWAKE -> if (value != null) {
                set("awake", "setting", JsonPrimitive(value)); set("awake", "holding", JsonPrimitive(value == "lidClosed"))
            }
            MacAction.WORKSPACE_START, MacAction.WORKSPACE_STOP -> {
                val start = action == MacAction.WORKSPACE_START
                val step = state.workspaceStepMillis
                if (step != null) {
                    moveWorkspace(if (start) listOf("starting", "running") else listOf("closing", "stopped"), step)
                } else {
                    setWorkspace(if (start) "starting" else "stopped")
                    return@synchronized state.macStatus
                }
            }
            MacAction.BITWARDEN_LOCK -> set("bitwarden", "state", JsonPrimitive("locked"))
            MacAction.SESSION_RESTART -> set("session", "state", JsonPrimitive("restarting"))
            MacAction.DISPLAY_OFF -> set("display", "state", JsonPrimitive("off"))
            MacAction.DISPLAY_ON -> set("display", "state", JsonPrimitive("on"))
            MacAction.WORKSPACE_SIGN_OUT -> if (status["workspace"].obj?.get("state").str == "stopped") {
                set("workspace", "signOutPending", JsonPrimitive(true))
            }
            else -> Unit
        }
        if (action.raw.startsWith("chats.")) set("kept", "running", JsonPrimitive(state.chats.count { it.state == "running" }))
        state.macStatus = JsonObject(status)
        state.macStatus
    }

    /** The workspace in another state, in both statuses (`status` and `mac.status`). */
    private fun setWorkspace(name: String) {
        val w = (state.macStatus["workspace"].obj ?: JsonObject(emptyMap())).toMutableMap()
        w["state"] = JsonPrimitive(name)
        state.workspace = state.workspace.copy(state = WorkspaceState(name))
        if (name == "stopped") {
            w.remove("purpose"); w.remove("until")
            state.workspace = state.workspace.copy(purpose = "", until = null)
        }
        state.macStatus = JsonObject(state.macStatus + ("workspace" to JsonObject(w)))
    }

    private fun moveWorkspace(states: List<String>, stepMillis: Long) {
        scope.launch {
            for (name in states) {
                delay(stepMillis)
                synchronized(lock) { setWorkspace(name) }
                emit(CompanionEvent.Workspace(WorkspaceState(name)))
            }
        }
    }

    // Chats (as aOS on the Mac, without its keeper's timing)

    private fun chatAction(action: MacAction, id: String?): Pair<String?, String>? = synchronized(lock) {
        if (action == MacAction.CHATS_LIST) return@synchronized null
        val index = state.chats.indexOfFirst { it.id == id }
        if (id == null || index < 0) {
            return@synchronized if (action == MacAction.CHATS_DELETE) "not-found" to "No such conversation." else null to "Not a conversation: ${id ?: ""}"
        }
        var c = state.chats[index]
        when (action) {
            MacAction.CHATS_PIN, MacAction.CHATS_START -> {
                c = c.copy(pinned = true, skipped = false)
                if (!c.isReachable) c = c.copy(state = "starting", detail = null, note = null, reason = null, since = Instant.now())
            }
            MacAction.CHATS_UNPIN -> c = c.copy(pinned = false)
            MacAction.CHATS_SKIP, MacAction.CHATS_STOP ->
                c = c.copy(skipped = true, pinned = false, state = null, detail = null, note = null, reason = "skipped")
            MacAction.CHATS_UNSKIP -> c = c.copy(skipped = false, reason = if (c.origin == "terminal") "terminal" else "overLimit")
            MacAction.CHATS_RESTART -> {
                if ((c.state ?: "") !in listOf("running", "starting", "needsAttention", "failed")) {
                    return@synchronized "not-kept" to "aOS doesn't run this conversation right now, so there is nothing to restart."
                }
                c = c.copy(state = "starting", detail = "restarting", note = "restarting", since = Instant.now())
            }
            MacAction.CHATS_DELETE -> {
                if (!c.isIdle) return@synchronized "chat-running" to "The conversation is running or open. Stop it first, or close it in the Claude app."
                state.chats = state.chats.filterIndexed { i, _ -> i != index }
                return@synchronized null
            }
            else -> Unit
        }
        state.chats = ordered(state.chats.toMutableList().also { it[index] = c })
        null
    }

    private fun chatsJson(): JsonObject = synchronized(lock) {
        val list = state.chats.map { c ->
            val o = mutableMapOf<String, JsonElement>("id" to JsonPrimitive(c.id), "title" to JsonPrimitive(c.title),
                "folder" to JsonPrimitive(c.folder), "pinned" to JsonPrimitive(c.pinned), "skipped" to JsonPrimitive(c.skipped))
            c.origin?.let { o["origin"] = JsonPrimitive(it) }
            c.activity?.let { o["activity"] = JsonPrimitive(Iso8601.format(it)) }
            c.state?.let { o["state"] = JsonPrimitive(it) }
            c.detail?.let { o["detail"] = JsonPrimitive(it) }
            c.note?.let { o["note"] = JsonPrimitive(it) }
            c.since?.let { o["since"] = JsonPrimitive(Iso8601.format(it)) }
            c.reason?.let { o["reason"] = JsonPrimitive(it) }
            JsonObject(o)
        }
        JsonObject(mapOf("enabled" to JsonPrimitive(state.chatsEnabled), "automatic" to JsonPrimitive(true),
            "terminal" to JsonPrimitive(false), "hours" to JsonPrimitive(48), "max" to JsonPrimitive(6),
            "running" to JsonPrimitive(state.chats.count { it.state == "running" }), "restart" to JsonPrimitive(true),
            "list" to JsonArray(list)))
    }

    // Signatures (as aOS on the Mac checks them)

    private fun check(op: String, o: JsonObject, trusted: TrustedSigner): Pair<String, String>? {
        val auth = CompanionAuth.from(o["auth"])
        if (auth == null || auth.key != trusted.phoneId) {
            return "pair-again" to "This phone can't approve on this Mac until it is paired again."
        }
        if (kotlin.math.abs(auth.ts - Instant.now().epochSecond) > 120) {
            return "clock" to "The phone's clock and the Mac's differ by more than 2 minutes."
        }
        val message = CompanionSignature.message(MacSideSignature.fields(op, o, auth))
        val raw = Bytes.base64Decode(auth.sig)
        val key = P256.publicKey(trusted.publicKeyX963)
        if (message == null || raw == null || raw.size != 64 || key == null || !P256.verify(key, message, raw)) {
            return "invalid" to "The request's signature doesn't check out."
        }
        if (!synchronized(lock) { nonces.add(auth.nonce) }) return "invalid" to "This request was sent before."
        return null
    }

    companion object {
        /** A MacBook on battery with the lid open, staying awake with the lid closed, the workspace open for the agent. */
        fun demoMacStatus(): JsonObject = Json.parseObject(Bytes.utf8("""
            {"power":{"source":"battery","battery":76,"charging":false,"minutes":312,"lid":"open","thermal":"nominal"},
             "display":{"state":"on","external":0},
             "awake":{"setting":"lidClosed","holding":true,"lidClosedMode":false,"helper":"enabled","otherService":false},
             "workspace":{"state":"open","setupComplete":true,"purpose":"Rechnungen herunterladen","until":"${Iso8601.format(Instant.now().plusSeconds(1500))}"},
             "session":{"enabled":true,"state":"running","since":"${Iso8601.format(Instant.now().minusSeconds(3 * 3600))}"},
             "newChats":{"enabled":true,"state":"running"},
             "kept":{"enabled":true,"running":2},
             "bitwarden":{"state":"unlocked"}}
        """.trimIndent()))!!

        fun demoChats(now: Instant = Instant.now()): List<ChatList.Chat> {
            fun ago(minutes: Long) = now.minusSeconds(minutes * 60)
            return ordered(listOf(
                ChatList.Chat("6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e01", "aOS: Chats auf dem iPhone", "~/Developer/annex", "app",
                    ago(4), pinned = true, state = "running", since = ago(180)),
                ChatList.Chat("6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e02", "Bachelorarbeit: Gliederung", "~/Uni/Bachelorarbeit", "app",
                    ago(2), state = "openElsewhere", detail = "open in the Claude app", note = "app", since = ago(2)),
                ChatList.Chat("6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e05", "Morgenbriefing", "~/cloupi", "app", ago(300),
                    skipped = true, reason = "skipped"),
                ChatList.Chat("6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e07", "Umzugskartons zählen", "~", "app", ago(4 * 24 * 60),
                    reason = "inactive"),
            ))
        }

        /** The Mac's order: reachable first, then pinned, then by the person's last activity. */
        fun ordered(chats: List<ChatList.Chat>): List<ChatList.Chat> = chats.sortedWith(Comparator { a, b ->
            when {
                a.isReachable != b.isReachable -> if (a.isReachable) -1 else 1
                a.pinned != b.pinned -> if (a.pinned) -1 else 1
                a.activity != b.activity -> (b.activity ?: Instant.MIN).compareTo(a.activity ?: Instant.MIN)
                else -> a.id.compareTo(b.id)
            }
        })

        /** An event as the Mac writes it (one line with its "\n"). */
        fun line(event: CompanionEvent): ByteArray {
            fun s(v: String) = JsonPrimitive(v)
            val o: Map<String, JsonElement> = when (event) {
                is CompanionEvent.SignIn -> event.request.let { r ->
                    buildMap {
                        put("event", s("signin")); put("request", s(r.id)); put("agent", s(r.agent)); put("host", s(r.host))
                        put("purpose", s(r.purpose)); r.expires?.let { put("expires", s(Iso8601.format(it))) }
                        put("field", s(r.field.raw)); put("bitwarden", s(r.bitwarden.raw))
                        put("logins", JsonArray(r.logins.map {
                            JsonObject(mapOf("id" to s(it.id), "name" to s(it.name), "username" to s(it.username), "totp" to JsonPrimitive(it.hasCode)))
                        }))
                    }
                }
                is CompanionEvent.SignInClosed -> mapOf("event" to s("signin.closed"), "request" to s(event.request), "result" to s(event.result.raw))
                is CompanionEvent.Help -> event.request.let { h ->
                    buildMap {
                        put("event", s("help")); put("request", s(h.id)); put("agent", s(h.agent)); put("purpose", s(h.purpose))
                        h.region?.let { r ->
                            put("region", JsonObject(mapOf("x" to Json.number(r.x), "y" to Json.number(r.y), "w" to Json.number(r.width), "h" to Json.number(r.height))))
                        }
                    }
                }
                is CompanionEvent.HelpClosed -> mapOf("event" to s("help.closed"), "request" to s(event.request))
                is CompanionEvent.Approval -> event.request.let { a ->
                    buildMap {
                        put("event", s("approval")); put("request", s(a.id)); put("agent", s(a.agent)); put("purpose", s(a.purpose))
                        a.minutes?.let { put("minutes", JsonPrimitive(it)) }
                        a.expires?.let { put("expires", s(Iso8601.format(it))) }
                    }
                }
                is CompanionEvent.ApprovalClosed -> mapOf("event" to s("approval.closed"), "request" to s(event.request), "result" to s(event.result.raw))
                is CompanionEvent.Mac -> mapOf("event" to s("mac"), "state" to s(event.state), "detail" to s(event.detail))
                is CompanionEvent.Workspace -> mapOf("event" to s("workspace"), "state" to s(event.state.name))
                CompanionEvent.Chats -> mapOf("event" to s("chats"))
                CompanionEvent.SubscriptionEnded -> mapOf("event" to s("subscription"), "state" to s("ended"))
            }
            return Json.line(JsonObject(o))
        }
    }
}

/** Client side of the in-memory connection. */
private class MemoryTransport(private val server: MockCompanionServer, private val toClient: Channel<ByteArray>) : CompanionTransport {
    private val feeder = MockCompanionServer.Feeder(server)
    @Volatile private var closed = false

    override suspend fun send(data: ByteArray) {
        if (closed) throw CompanionError.Closed
        feeder.feed(data)
    }

    override fun incoming(): Flow<ByteArray> = toClient.receiveAsFlow()

    override suspend fun close() {
        closed = true
        server.disconnect()
    }
}
