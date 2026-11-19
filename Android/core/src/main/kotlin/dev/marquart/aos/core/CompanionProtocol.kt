package dev.marquart.aos.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.security.SecureRandom
import java.time.Instant

// The companion API between the phone and `aos-companion serve` on the Mac (Docs/COMPANION.md, "Companion API"):
// JSON lines in both directions (UTF-8, one object per line). Requests carry an `id`; answers repeat it with `ok` and
// either a result or `error`. After `subscribe` the Mac sends events without `id` at any time.

enum class ScreenTarget(val raw: String) {
    /** The paired Mac's own screen (screen sharing on 127.0.0.1:5900 of the Mac). */
    MAC("mac"),

    /** The aOS workspace, the virtual Mac. */
    WORKSPACE("workspace");

    companion object {
        fun from(raw: String?): ScreenTarget? = entries.firstOrNull { it.raw == raw }
    }
}

/** The command line for the companion's exec channel. sshd hands exec commands to the login shell, so the path is
 *  quoted for it. */
object CompanionCommand {
    const val DEFAULT_PATH = "/Applications/aOS.app/Contents/MacOS/aos-companion"

    fun serve(path: String): String = shellQuoted(path) + " serve"

    /** `'...'` with embedded single quotes written as `'\''`. */
    fun shellQuoted(text: String): String = "'" + text.replace("'", "'\\''") + "'"
}

/** Requests from the phone. */
sealed class CompanionRequest {
    data class Hello(val app: String, val device: String) : CompanionRequest()
    data object Status : CompanionRequest()
    data object Subscribe : CompanionRequest()

    /** Where a screen is. `reply` (the workspace): this request's one-time key-agreement key, base64 X9.63; the Mac
     *  seals the login to it (`ScreenSeal`), and the signature covers it. */
    data class Screen(val target: ScreenTarget, val reply: String? = null) : CompanionRequest()

    /** A Bitwarden login the person approved (its id). `host`: the request's website, as the person saw it. */
    data class SignInLogin(val request: String, val host: String, val login: String) : CompanionRequest()

    /** A sign-in from another password app (AutoFill). Never logged, never stored. */
    data class SignInAnswer(val request: String, val host: String, val username: String, val password: String,
                            val totp: String?) : CompanionRequest() {
        override fun toString() = "SignInAnswer(request=$request, host=$host, <values hidden>)"
    }

    data class SignInDecline(val request: String, val host: String) : CompanionRequest()

    /** A one-time code, for a request whose field is `code` (only `totp` goes out). */
    data class SignInCode(val request: String, val host: String, val totp: String) : CompanionRequest() {
        override fun toString() = "SignInCode(request=$request, host=$host, <code hidden>)"
    }

    data class HelpDone(val request: String) : CompanionRequest()

    /** Whether the agent may open the workspace. */
    data class ApprovalAnswer(val request: String, val allowed: Boolean) : CompanionRequest()

    /** Types text into the running workspace. */
    data class Type(val text: String) : CompanionRequest()

    /** The workspace's display in the phone's shape: `size` is "WIDTHxHEIGHT@SCALE" or "reset". */
    data class Display(val target: ScreenTarget, val size: String) : CompanionRequest()

    /** The Overview: the Mac's status, or an action on the Mac or aOS (`value` for the parameter, as `text`). */
    data class Mac(val action: MacAction, val value: String? = null) : CompanionRequest()

    val op: String
        get() = when (this) {
            is Hello -> "hello"
            Status -> "status"
            Subscribe -> "subscribe"
            is Screen -> "screen"
            is SignInLogin, is SignInAnswer, is SignInDecline, is SignInCode -> "signin.answer"
            is HelpDone -> "help.done"
            is ApprovalAnswer -> "approval.answer"
            is Type -> "type"
            is Display -> "display"
            is Mac -> action.raw
        }

    /** The operation as aOS on the Mac gets it from `aos-companion` (what the signature names). */
    val signedOp: String
        get() = when (this) {
            is Hello, Status, Subscribe, is Screen, is Type, is Display, is Mac -> "companion.$op"
            else -> op
        }

    /** What the Mac reads from this request to check its signature (Docs/COMPANION.md, "Signed requests"). */
    fun signatureFields(key: String, ts: Long, nonce: String): CompanionSignature.Fields {
        val f = CompanionSignature.Fields(op = signedOp, key = key, ts = ts, nonce = nonce)
        return when (this) {
            is Hello, Status, Subscribe -> f
            is Screen -> f.copy(target = target.raw, data = CompanionSignature.dataDigest(reply = reply))
            is SignInLogin -> f.copy(request = request, host = host, decision = "login", login = login)
            is SignInAnswer -> f.copy(request = request, host = host, decision = "fill",
                data = CompanionSignature.dataDigest(username = username, password = password, totp = sentTotp(totp)))
            is SignInDecline -> f.copy(request = request, host = host, decision = "decline")
            is SignInCode -> f.copy(request = request, host = host, decision = "code",
                data = CompanionSignature.dataDigest(totp = totp))
            is HelpDone -> f.copy(request = request, decision = "done")
            is ApprovalAnswer -> f.copy(request = request, decision = if (allowed) "allow" else "deny")
            is Type -> f.copy(data = CompanionSignature.dataDigest(text = text))
            is Display -> f.copy(target = target.raw, data = CompanionSignature.dataDigest(text = size))
            // The parameter is the text, which the signature covers.
            is Mac -> if (value != null) f.copy(data = CompanionSignature.dataDigest(text = value)) else f
        }
    }

    /** The request as one JSON line (with its "\n"), with the phone's signature if given. */
    fun line(id: Int, auth: CompanionAuth? = null): ByteArray {
        val o = LinkedHashMap<String, JsonElement>()
        o["id"] = JsonPrimitive(id)
        o["op"] = JsonPrimitive(op)
        when (this) {
            is Hello -> { o["app"] = JsonPrimitive(app); o["device"] = JsonPrimitive(device) }
            Status, Subscribe -> Unit
            is Screen -> { o["target"] = JsonPrimitive(target.raw); reply?.let { o["reply"] = JsonPrimitive(it) } }
            is SignInLogin -> { o["request"] = JsonPrimitive(request); o["host"] = JsonPrimitive(host); o["login"] = JsonPrimitive(login) }
            is SignInAnswer -> {
                o["request"] = JsonPrimitive(request); o["host"] = JsonPrimitive(host)
                o["username"] = JsonPrimitive(username); o["password"] = JsonPrimitive(password)
                sentTotp(totp)?.let { o["totp"] = JsonPrimitive(it) }
            }
            is SignInDecline -> { o["request"] = JsonPrimitive(request); o["host"] = JsonPrimitive(host); o["decline"] = JsonPrimitive(true) }
            is SignInCode -> { o["request"] = JsonPrimitive(request); o["host"] = JsonPrimitive(host); o["totp"] = JsonPrimitive(totp) }
            is HelpDone -> o["request"] = JsonPrimitive(request)
            is ApprovalAnswer -> { o["request"] = JsonPrimitive(request); o["allowed"] = JsonPrimitive(allowed) }
            is Type -> o["text"] = JsonPrimitive(text)
            is Display -> { o["target"] = JsonPrimitive(target.raw); o["text"] = JsonPrimitive(size) }
            is Mac -> value?.let { o["text"] = JsonPrimitive(it) }
        }
        auth?.let { o["auth"] = it.json }
        return Json.line(JsonObject(o))
    }

    private companion object {
        /** The totp that goes out with an AutoFill answer (an empty one doesn't). */
        fun sentTotp(totp: String?): String? = totp?.takeIf { it.isNotEmpty() }
    }
}

/** The signature on a request (`"auth"` in its line). The Mac checks it before it does anything. */
data class CompanionAuth(
    /** This phone's id on the Mac: first 12 hex characters of the SHA-256 of its SSH key blob. */
    val key: String,
    /** Unix time in seconds; the Mac takes it within 2 minutes of its own clock. */
    val ts: Long,
    /** 16 random bytes, base64url without padding; never the same twice. */
    val nonce: String,
    /** ECDSA P-256 with SHA-256 over `CompanionSignature.message`: r and s (64 bytes), base64. */
    val sig: String,
) {
    val json: JsonObject
        get() = sortedJsonObject("key" to JsonPrimitive(key), "ts" to JsonPrimitive(ts), "nonce" to JsonPrimitive(nonce),
            "sig" to JsonPrimitive(sig))

    companion object {
        fun from(value: JsonElement?): CompanionAuth? {
            val o = value.obj ?: return null
            return CompanionAuth(o["key"].str ?: return null, o["ts"].long ?: return null, o["nonce"].str ?: return null,
                o["sig"].str ?: return null)
        }
    }
}

/**
 * What the phone signs, the same text the Mac rebuilds (AOSKit `CompanionSignature`): these lines, UTF-8, joined with
 * "\n" and no newline at the end. No value may contain a line break.
 *
 *     aos-companion-v1
 *     op=<companion.hello|...|signin.answer|help.done|approval.answer>
 *     key=<phone id>
 *     ts=<seconds>
 *     nonce=<nonce>
 *     request=<request id or empty>
 *     decision=<login|fill|code|decline, allow|deny, done, or empty>
 *     login=<Bitwarden item id or empty>
 *     host=<the sign-in's website or empty>
 *     target=<mac|workspace or empty>
 *     data=<dataDigest of user name, password, code, typed text, a screen request's reply key>
 */
object CompanionSignature {
    const val VERSION = "aos-companion-v1"

    data class Fields(
        val op: String,
        val key: String,
        val ts: Long,
        val nonce: String,
        val request: String = "",
        val decision: String = "",
        val login: String = "",
        val host: String = "",
        val target: String = "",
        val data: String = dataDigest(),
    )

    /** The bytes that are signed, or null if a value has a line break. */
    fun message(f: Fields): ByteArray? {
        val values = listOf(f.op, f.key, f.ts.toString(), f.nonce, f.request, f.decision, f.login, f.host, f.target, f.data)
        if (values.any { it.contains('\n') || it.contains('\r') }) return null
        val lines = listOf(VERSION, "op=${f.op}", "key=${f.key}", "ts=${f.ts}", "nonce=${f.nonce}", "request=${f.request}",
            "decision=${f.decision}", "login=${f.login}", "host=${f.host}", "target=${f.target}", "data=${f.data}")
        return Bytes.utf8(lines.joinToString("\n"))
    }

    /** For each field present, in this order: `<name>:<UTF-8 byte count>:<value>\n`; SHA-256 of that, lowercase hex.
     *  `reply` is a screen request's one-time key (absent everywhere else). */
    fun dataDigest(username: String? = null, password: String? = null, totp: String? = null, text: String? = null,
                   reply: String? = null): String {
        val out = java.io.ByteArrayOutputStream()
        for ((name, value) in listOf("username" to username, "password" to password, "totp" to totp, "text" to text,
            "reply" to reply)) {
            if (value == null) continue
            val bytes = Bytes.utf8(value)
            out.write(Bytes.utf8("$name:${bytes.size}:"))
            out.write(bytes)
            out.write(0x0A)
        }
        return Bytes.hex(Bytes.sha256(out.toByteArray()))
    }
}

/** Signs the companion requests of this phone: its phone id (as the Mac knows it) and its signing key. */
class CompanionSigner(
    /** First 12 hex characters of the SHA-256 of this phone's SSH key (the Mac's id for it). */
    val phoneId: String,
    val key: P256Signer,
    private val random: SecureRandom = SecureRandom(),
    private val clock: () -> Instant = Instant::now,
) {
    /** A fresh signature for `request`: now, a new nonce. */
    fun auth(request: CompanionRequest): CompanionAuth {
        val bytes = ByteArray(16)
        random.nextBytes(bytes)
        val ts = clock().epochSecond
        val nonce = Bytes.base64UrlEncode(bytes)
        val message = CompanionSignature.message(request.signatureFields(phoneId, ts, nonce))
            ?: throw CompanionUnsignableException()
        return CompanionAuth(phoneId, ts, nonce, Bytes.base64(key.sign(message)))
    }
}

/** The request has a value that can't be signed (a line break where none may be). */
class CompanionUnsignableException : Exception("This request couldn't be signed.")

/** An answer to a request. */
data class CompanionResponse(
    val id: Int,
    val ok: Boolean,
    val error: String? = null,
    val body: JsonObject = JsonObject(emptyMap()),
) {
    /** Why the Mac refused: "pair-again" (it has no signing key for this phone), "clock", "invalid", or an
     *  Overview code. */
    val code: String? get() = body["code"].str
}

/** The workspace's state; `running`: it runs without an agent's session (started from the phone or the Mac). */
data class WorkspaceState(val name: String) {
    /** Its screen can be shown (with or without an agent's session). */
    val isViewable: Boolean get() = name == "open" || name == "running"

    companion object {
        val STOPPED = WorkspaceState("stopped")
        val STARTING = WorkspaceState("starting")
        val RUNNING = WorkspaceState("running")
        val OPEN = WorkspaceState("open")
        val CLOSING = WorkspaceState("closing")
    }
}

/** A Bitwarden login the Mac offers for a sign-in: which one, never its password or authenticator key. */
data class BitwardenLogin(val id: String, val name: String, val username: String, val hasCode: Boolean)

/** Bitwarden in aOS on the Mac, as a sign-in request reports it. Missing or unknown counts as OFF. */
enum class BitwardenState(val raw: String) {
    UNLOCKED("unlocked"), LOCKED("locked"), OFF("off"), UNAVAILABLE("unavailable");

    companion object {
        fun from(raw: String?): BitwardenState = entries.firstOrNull { it.raw == raw } ?: OFF
    }
}

/** A sign-in the agent asks for. Shown to the person, who approves or declines it. */
data class SignInRequest(
    val id: String,
    val agent: String,
    val host: String,
    val purpose: String,
    val expires: Instant? = null,
    val field: Field = Field.PASSWORD,
    /** The person's Bitwarden logins for the site, as the Mac found them (never a password). */
    val logins: List<BitwardenLogin> = emptyList(),
    val bitwarden: BitwardenState = BitwardenState.OFF,
) {
    /** Where the agent clicked on the page. A missing or unknown field counts as the password. */
    enum class Field(val raw: String) {
        USERNAME("username"), PASSWORD("password"),

        /** A one-time code: the answer carries the code only. */
        CODE("code");

        companion object {
            fun from(raw: String?): Field = entries.firstOrNull { it.raw == raw } ?: PASSWORD
        }
    }

    /** The logins that can answer this request: all of them, for a code those with an authenticator key. */
    val choices: List<BitwardenLogin> get() = if (this.field == Field.CODE) logins.filter { it.hasCode } else logins
}

enum class SignInResult(val raw: String) {
    FILLED("filled"), DECLINED("declined"), EXPIRED("expired"), FAILED("failed"), UNKNOWN("unknown");

    companion object {
        fun from(raw: String?): SignInResult = entries.firstOrNull { it.raw == raw && it != UNKNOWN } ?: UNKNOWN
    }
}

/** The agent asks for help in the workspace (a captcha, a sign-in it can't do). */
data class HelpRequest(
    val id: String,
    val agent: String,
    val purpose: String,
    /** The part of the workspace screen (pixels) that needs the person, if the agent named one. */
    val region: Region? = null,
) {
    data class Region(val x: Double, val y: Double, val width: Double, val height: Double) {
        val isEmpty: Boolean get() = width <= 0 || height <= 0
    }
}

/** An agent that can't ask by itself wants to open the workspace. */
data class ApprovalRequest(
    val id: String,
    val agent: String,
    val purpose: String,
    /** How long the workspace would stay open. */
    val minutes: Int? = null,
    val expires: Instant? = null,
)

enum class ApprovalResult(val raw: String) {
    ALLOWED("allowed"), DECLINED("declined"), UNKNOWN("unknown");

    companion object {
        fun from(raw: String?): ApprovalResult = entries.firstOrNull { it.raw == raw && it != UNKNOWN } ?: UNKNOWN
    }
}

sealed class CompanionEvent {
    data class SignIn(val request: SignInRequest) : CompanionEvent()
    data class SignInClosed(val request: String, val result: SignInResult) : CompanionEvent()
    data class Help(val request: HelpRequest) : CompanionEvent()
    data class HelpClosed(val request: String) : CompanionEvent()
    data class Approval(val request: ApprovalRequest) : CompanionEvent()
    data class ApprovalClosed(val request: String, val result: ApprovalResult) : CompanionEvent()

    /** `aos-companion` can't reach the Mac app (`unavailable`, it keeps trying), or can again. */
    data class Mac(val state: String, val detail: String) : CompanionEvent()
    data class Workspace(val state: WorkspaceState) : CompanionEvent()

    /** A chat started, ended or changed its state on the Mac: read the list again (`chats.list`). */
    data object Chats : CompanionEvent()

    /** The Mac ended the event subscription: subscribe again, signed. */
    data object SubscriptionEnded : CompanionEvent()
}

/** One decoded line from the Mac. */
sealed class CompanionMessage {
    data class Response(val response: CompanionResponse) : CompanionMessage()
    data class Event(val event: CompanionEvent) : CompanionMessage()

    /** Valid JSON the app doesn't know (a newer Mac); ignored. */
    data object Ignored : CompanionMessage()

    class DecodeException(val reason: String) : Exception(reason)

    companion object {
        /** Decodes one line; throws `DecodeException` ("notJSON", "notAnObject") for lines that aren't messages. */
        fun decode(line: ByteArray): CompanionMessage {
            val value = Json.parse(line) ?: throw DecodeException("notJSON")
            val o = value as? JsonObject ?: throw DecodeException("notAnObject")
            o["id"].int?.let { id ->
                return Response(CompanionResponse(id, o["ok"].bool ?: false, o["error"].str, o))
            }
            val name = o["event"].str ?: return Ignored
            val request = o["request"].str ?: ""
            return when (name) {
                "signin" -> {
                    val host = o["host"].str
                    if (request.isEmpty() || host.isNullOrEmpty()) return Ignored
                    val logins = (o["logins"].arr ?: JsonArray(emptyList())).mapNotNull { v ->
                        val l = v.obj ?: return@mapNotNull null
                        val id = l["id"].str?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                        BitwardenLogin(id, l["name"].str ?: "", l["username"].str ?: "", l["totp"].bool ?: false)
                    }
                    Event(CompanionEvent.SignIn(SignInRequest(
                        id = request, agent = o["agent"].str ?: "", host = host, purpose = o["purpose"].str ?: "",
                        expires = o["expires"].str?.let(Iso8601::parse), field = SignInRequest.Field.from(o["field"].str),
                        logins = logins, bitwarden = BitwardenState.from(o["bitwarden"].str))))
                }
                "signin.closed" -> if (request.isEmpty()) Ignored
                    else Event(CompanionEvent.SignInClosed(request, SignInResult.from(o["result"].str)))
                "help" -> {
                    if (request.isEmpty()) return Ignored
                    var region: HelpRequest.Region? = null
                    val r = o["region"].obj
                    if (r != null) {
                        val x = r["x"].num; val y = r["y"].num; val w = r["w"].num; val h = r["h"].num
                        if (x != null && y != null && w != null && h != null) {
                            region = HelpRequest.Region(x, y, w, h).takeUnless { it.isEmpty }
                        }
                    }
                    Event(CompanionEvent.Help(HelpRequest(request, o["agent"].str ?: "", o["purpose"].str ?: "", region)))
                }
                "help.closed" -> if (request.isEmpty()) Ignored else Event(CompanionEvent.HelpClosed(request))
                "approval" -> if (request.isEmpty()) Ignored else Event(CompanionEvent.Approval(ApprovalRequest(
                    request, o["agent"].str ?: "", o["purpose"].str ?: "", o["minutes"].int,
                    o["expires"].str?.let(Iso8601::parse))))
                "approval.closed" -> if (request.isEmpty()) Ignored
                    else Event(CompanionEvent.ApprovalClosed(request, ApprovalResult.from(o["result"].str)))
                "mac" -> o["state"].str?.let { Event(CompanionEvent.Mac(it, o["detail"].str ?: "")) } ?: Ignored
                "workspace" -> o["state"].str?.let { Event(CompanionEvent.Workspace(WorkspaceState(it))) } ?: Ignored
                "chats" -> Event(CompanionEvent.Chats)
                "subscription" -> if (o["state"].str == "ended") Event(CompanionEvent.SubscriptionEnded) else Ignored
                else -> Ignored
            }
        }
    }
}

// Results of requests

data class HelloResult(
    val mac: String,
    val aos: String,
    /** What this Mac offers beyond the first version ("mac.status", ..., "term"); empty for an older aOS. */
    val features: Set<String> = emptySet(),
) {
    companion object {
        fun from(r: CompanionResponse) = HelloResult(r.body["mac"].str ?: "", r.body["aos"].str ?: "",
            (r.body["features"].arr ?: JsonArray(emptyList())).mapNotNull { it.str }.toSet())
    }
}

data class WorkspaceStatus(
    val state: WorkspaceState,
    val purpose: String = "",
    val until: Instant? = null,
    val sessions: List<Session> = emptyList(),
) {
    data class Session(val id: Int, val title: String, val state: String)

    companion object {
        fun from(r: CompanionResponse): WorkspaceStatus {
            val w = r.body["workspace"].obj ?: JsonObject(emptyMap())
            val sessions = (r.body["sessions"].arr ?: JsonArray(emptyList())).withIndex().mapNotNull { (i, v) ->
                val s = v.obj ?: return@mapNotNull null
                Session(i, s["title"].str ?: "", s["state"].str ?: "")
            }
            return WorkspaceStatus(WorkspaceState(w["state"].str ?: "stopped"), w["purpose"].str ?: "",
                w["until"].str?.let(Iso8601::parse), sessions)
        }
    }
}

/** Where a screen is and how to log in to it. */
data class ScreenEndpoint(val host: String, val port: Int, val username: String? = null, val password: String? = null) {
    override fun toString() = "ScreenEndpoint(host=$host, port=$port, username=$username, password=${if (password == null) "null" else "<hidden>"})"

    companion object {
        fun from(r: CompanionResponse): ScreenEndpoint? = from(r.body)

        /** From an answer (the Mac's own screen), or from the workspace's sealed login once opened. */
        fun from(body: JsonObject): ScreenEndpoint? {
            val host = body["host"].str?.takeIf { it.isNotEmpty() } ?: return null
            val port = body["port"].int?.takeIf { it in 1..65535 } ?: return null
            return ScreenEndpoint(host, port, body["username"].str, body["password"].str)
        }
    }
}

/**
 * Splits a byte stream into lines ("\n", an optional "\r" before it is dropped). Lines longer than `limit` are an
 * error, so a broken peer can't make the app buffer without end.
 */
class LineSplitter(private val limit: Int = 1 shl 20) {
    private val buffer = java.io.ByteArrayOutputStream()

    class LineTooLongException : Exception("line too long")

    fun append(chunk: ByteArray): List<ByteArray> {
        val lines = mutableListOf<ByteArray>()
        var start = 0
        for (i in chunk.indices) {
            if (chunk[i] != 0x0A.toByte()) continue
            buffer.write(chunk, start, i - start)
            var line = buffer.toByteArray()
            buffer.reset()
            if (line.isNotEmpty() && line.last() == 0x0D.toByte()) line = line.copyOf(line.size - 1)
            lines += line
            start = i + 1
        }
        buffer.write(chunk, start, chunk.size - start)
        if (buffer.size() > limit) throw LineTooLongException()
        return lines
    }
}

/**
 * What aOS on the Mac signs over, read from a request line the way the Mac reads it: `aos-companion` passes on only the
 * fields each operation has, the app derives the decision from them (AOSKit `CompanionSignature.fields(for:auth:)`).
 * Used by the in-process Mac of the tests and the demo, and to check that what the phone signs is what the Mac rebuilds.
 */
object MacSideSignature {
    private val companionOps = setOf("hello", "status", "subscribe", "screen", "type", "display")

    fun fields(op: String, o: JsonObject, auth: CompanionAuth): CompanionSignature.Fields {
        val macOp = if (op in companionOps || MacAction.from(op) != null) "companion.$op" else op
        val f = CompanionSignature.Fields(op = macOp, key = auth.key, ts = auth.ts, nonce = auth.nonce)
        fun text(name: String) = o[name].str
        if (MacAction.from(op) != null) {
            // aos-companion passes on only the text; the app signs over it.
            return text("text")?.let { f.copy(data = CompanionSignature.dataDigest(text = it)) } ?: f
        }
        return when (op) {
            "screen" -> f.copy(target = if (text("target") == "workspace") "workspace" else "mac",
                data = CompanionSignature.dataDigest(reply = text("reply")))
            "signin.answer" -> {
                val decision = when {
                    o["decline"].bool == true -> "decline"
                    text("login") != null -> "login"
                    text("username") != null || text("password") != null -> "fill"
                    text("totp") != null -> "code"
                    else -> ""
                }
                f.copy(request = text("request") ?: "", host = text("host") ?: "", login = text("login") ?: "",
                    decision = decision, data = CompanionSignature.dataDigest(username = text("username"),
                        password = text("password"), totp = text("totp")))
            }
            "type" -> f.copy(data = CompanionSignature.dataDigest(text = text("text")))
            "display" -> f.copy(target = text("target") ?: "", data = CompanionSignature.dataDigest(text = text("text")))
            "help.done" -> f.copy(request = text("request") ?: "", decision = "done")
            "approval.answer" -> f.copy(request = text("request") ?: "",
                decision = if (o["allowed"].bool == true) "allow" else "deny")
            else -> f
        }
    }
}
