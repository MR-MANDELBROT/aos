package dev.marquart.aos.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.time.Instant

// The Overview's view of the Mac and aOS (Docs/COMPANION.md, "The Mac from the iPhone"): one signed op to read, one
// signed op per action. iOS Sources/Core/MacStatus.swift.

/** The Overview's ops (the phone's names; the Mac gets them as "companion." + name). */
enum class MacAction(val raw: String) {
    STATUS("mac.status"),
    SLEEP("mac.sleep"),
    DISPLAY_OFF("mac.display-off"),
    DISPLAY_ON("mac.display-on"),
    STAY_AWAKE("mac.stay-awake"),
    BATTERY_LIMIT("mac.battery-limit"),
    WORKSPACE_START("workspace.start"),
    WORKSPACE_STOP("workspace.stop"),

    /** Sign the workspace out of every website (at once, or at its next start). */
    WORKSPACE_SIGN_OUT("workspace.sign-out"),
    BITWARDEN_LOCK("bitwarden.lock"),
    SESSION_RESTART("session.restart"),

    /** The session's routines: add or change one (JSON), delete one, send one now (its id). */
    ROUTINE_SET("routines.set"),
    ROUTINE_DELETE("routines.delete"),
    ROUTINE_RUN("routines.run"),

    /** The chats: the list, and one change per op with the chat's id as the value. */
    CHATS_LIST("chats.list"),
    CHATS_PIN("chats.pin"),
    CHATS_UNPIN("chats.unpin"),
    CHATS_SKIP("chats.skip"),
    CHATS_UNSKIP("chats.unskip"),
    CHATS_RESTART("chats.restart"),
    CHATS_START("chats.start"),
    CHATS_STOP("chats.stop"),
    CHATS_DELETE("chats.delete");

    /** Changes a chat (the list answers with the new one, the keeper on the Mac follows a moment later). */
    val changesChat: Boolean get() = raw.startsWith("chats.") && this != CHATS_LIST

    companion object {
        fun from(raw: String?): MacAction? = entries.firstOrNull { it.raw == raw }
    }
}

/** When aOS keeps the Mac awake (AOSKit `StayAwake`). */
enum class MacStayAwake(val raw: String) {
    OFF("off"), LID_OPEN("lidOpen"), LID_CLOSED("lidClosed");

    companion object {
        fun from(raw: String?): MacStayAwake? = entries.firstOrNull { it.raw == raw }
    }
}

private fun date(v: JsonElement?): Instant? = v.str?.let(Iso8601::parse)
private val emptyArray = JsonArray(emptyList())

/** The Mac and aOS as `mac.status` reports them. Fields a Mac leaves out stay null. */
data class MacStatus(
    val power: Power? = null,
    /** null from an older aOS (it doesn't say). */
    val display: Display? = null,
    val awake: Awake? = null,
    val workspace: Workspace? = null,
    val session: Session? = null,
    val newChats: NewChats? = null,
    /** Kept conversations running now (null: the setting is off). */
    val kept: Int? = null,
    val bitwarden: Vault? = null,
    val routines: Routines? = null,
    /** null while installing apps on the phone is off on the Mac (or from an older aOS). */
    val apps: Apps? = null,
) {
    data class Power(
        /** ac, battery, ups, unknown */
        val source: String,
        val battery: Int? = null,
        val charging: Boolean? = null,
        /** Until empty on battery, until full while charging. */
        val minutes: Int? = null,
        /** open, closed, none (a Mac without a lid) */
        val lid: String,
        /** nominal, fair, serious, critical */
        val thermal: String,
    )

    data class Display(
        /** on (a screen is lit), off (all asleep), none (no screen: the lid closed without a monitor) */
        val state: String,
        /** Monitors besides the built-in screen. */
        val external: Int,
    )

    data class Awake(
        val setting: MacStayAwake,
        val holding: Boolean,
        val lidClosedMode: Boolean,
        /** cloupi, nothingToKeep, helperNotReady, lowBattery, thermal */
        val blocker: String? = null,
        /** enabled, requiresApproval, notRegistered, notFound */
        val helper: String,
        /** Another service owns sleep on this Mac. */
        val otherService: Boolean,
        /** On battery with the lid closed: awake down to this level (0: no limit); null from an older Mac. */
        val batteryLimit: Int? = null,
        val batteryLimits: List<Int> = emptyList(),
    )

    data class Workspace(
        /** stopped, starting, running, open, closing, failed */
        val state: String,
        val setupComplete: Boolean,
        val purpose: String? = null,
        val until: Instant? = null,
        val error: String? = null,
        /** Whether websites stay signed in after it closes: kept, some, expire (null: a Mac that doesn't say). */
        val signIns: String? = null,
        /** A sign-out of all websites waits for its next start. */
        val signOutPending: Boolean = false,
    )

    data class Session(
        val enabled: Boolean,
        /** starting, running, waitingForNetwork, needsLogin, needsAttention, missingClaude, restarting, stopped, failed */
        val state: String? = null,
        val detail: String? = null,
        val since: Instant? = null,
    )

    data class NewChats(
        val enabled: Boolean,
        /** off, waitingForNetwork, starting, running, needsLogin, needsTrust, missingClaude, restarting */
        val state: String? = null,
    )

    data class Vault(
        /** unlocked, locked, signedOut, needsHelper, unknown */
        val state: String,
        val until: Instant? = null,
    )

    /** aOS's session's routines, reminders waiting for it and what went in lately (null from an older aOS). */
    data class Routines(
        val items: List<Item>,
        val reminders: List<Upcoming> = emptyList(),
        val queued: Int = 0,
        val recent: List<Sent> = emptyList(),
        /** The Mac takes a model and an effort per routine (false: an older aOS, the editor leaves them out). */
        val overrides: Boolean = false,
    ) {
        data class Item(
            val id: String,
            val name: String,
            /** Cron, five fields, the Mac's local time. */
            val schedule: String,
            val prompt: String,
            val enabled: Boolean,
            val next: Instant? = null,
            /** Claude Code's model and effort for this routine (null: the session's own; AOSKit `Routine`). */
            val model: String? = null,
            val effort: String? = null,
        ) {
            /** The routine as `routines.set` sends it (without its next time, which is the Mac's). Model and effort
             *  always ("": the session's own), so the Mac can tell a cleared one from a phone that doesn't know them. */
            val json: String
                get() = Json.encode(sortedJsonObject("id" to kotlinx.serialization.json.JsonPrimitive(id),
                    "name" to kotlinx.serialization.json.JsonPrimitive(name),
                    "schedule" to kotlinx.serialization.json.JsonPrimitive(schedule),
                    "prompt" to kotlinx.serialization.json.JsonPrimitive(prompt),
                    "enabled" to kotlinx.serialization.json.JsonPrimitive(enabled),
                    "model" to kotlinx.serialization.json.JsonPrimitive(model ?: ""),
                    "effort" to kotlinx.serialization.json.JsonPrimitive(effort ?: "")))

            companion object {
                /** The models the editor offers (Claude Code's aliases; AOSKit `Routine.modelChoices`). */
                val models = listOf("opus", "opus[1m]", "sonnet", "sonnet[1m]", "haiku")
                /** The effort levels (AOSKit `Routine.effortChoices`). */
                val efforts = listOf("low", "medium", "high", "xhigh", "max")
            }
        }

        data class Upcoming(val name: String, val at: Instant)

        /** kind: routine, reminder, note, start */
        data class Sent(val kind: String, val name: String, val at: Instant)

        /** The routine that runs next. */
        val next: Item? get() = items.filter { it.enabled && it.next != null }.minByOrNull { it.next!! }
    }

    /** Installing apps on this phone (AOSKit `CompanionControl.apps`). States the phone doesn't know stay as they come. */
    data class Apps(
        /** connected, searching, connecting, notPaired, starting, stopped, unknown */
        val state: String,
        val since: Instant? = null,
        /** wifi, cellular (only while connected) */
        val network: String? = null,
        val device: String? = null,
        val previousSeconds: Int? = null,
        /** Newest first, at most 10. */
        val jobs: List<Job> = emptyList(),
    ) {
        data class Job(
            val id: String,
            val name: String,
            val bundleId: String,
            /** queued, installing, done, failed */
            val state: String,
            val created: Instant? = null,
            val version: String? = null,
            val source: String? = null,
            val finished: Instant? = null,
            val seconds: Double? = null,
            val network: String? = null,
            val message: String? = null,
        ) {
            val isPending: Boolean get() = state == "queued" || state == "installing"
        }

        val isConnected: Boolean get() = state == "connected"
        val queued: Int get() = jobs.count { it.state == "queued" }
        val installing: Int get() = jobs.count { it.state == "installing" }
    }

    companion object {
        fun from(o: JsonObject): MacStatus {
            val power = o["power"].obj?.let { p ->
                Power(p["source"].str ?: "unknown", p["battery"].int, p["charging"].bool, p["minutes"].int,
                    p["lid"].str ?: "none", p["thermal"].str ?: "nominal")
            }
            val display = o["display"].obj?.let { d -> d["state"].str?.let { Display(it, d["external"].int ?: 0) } }
            val awake = o["awake"].obj?.let { a ->
                MacStayAwake.from(a["setting"].str)?.let { setting ->
                    Awake(setting, a["holding"].bool ?: false, a["lidClosedMode"].bool ?: false, a["blocker"].str,
                        a["helper"].str ?: "notRegistered", a["otherService"].bool ?: false, a["batteryLimit"].int,
                        (a["batteryLimits"].arr ?: emptyArray).mapNotNull { it.int })
                }
            }
            val workspace = o["workspace"].obj?.let { w ->
                Workspace(w["state"].str ?: "stopped", w["setupComplete"].bool ?: true, w["purpose"].str, date(w["until"]),
                    w["error"].str, w["signIns"].str, w["signOutPending"].bool ?: false)
            }
            val session = o["session"].obj?.let { s ->
                Session(s["enabled"].bool ?: true, s["state"].str, s["detail"].str, date(s["since"]))
            }
            val newChats = o["newChats"].obj?.let { c -> NewChats(c["enabled"].bool ?: false, c["state"].str) }
            val kept = o["kept"].obj?.let { k -> if (k["enabled"].bool == true) k["running"].int ?: 0 else null }
            val bitwarden = o["bitwarden"].obj?.let { b -> b["state"].str?.let { Vault(it, date(b["until"])) } }
            val routines = o["routines"].obj?.let { r ->
                val items = (r["items"].arr ?: emptyArray).mapNotNull { v ->
                    val i = v.obj ?: return@mapNotNull null
                    val id = i["id"].str ?: return@mapNotNull null
                    val name = i["name"].str ?: return@mapNotNull null
                    val schedule = i["schedule"].str ?: return@mapNotNull null
                    Routines.Item(id, name, schedule, i["prompt"].str ?: "", i["enabled"].bool ?: true, date(i["next"]),
                        i["model"].str?.takeIf { it.isNotEmpty() }, i["effort"].str?.takeIf { it.isNotEmpty() })
                }
                val reminders = (r["reminders"].arr ?: emptyArray).mapNotNull { v ->
                    val i = v.obj ?: return@mapNotNull null
                    date(i["at"])?.let { Routines.Upcoming(i["name"].str ?: "", it) }
                }
                val recent = (r["recent"].arr ?: emptyArray).mapNotNull { v ->
                    val i = v.obj ?: return@mapNotNull null
                    date(i["at"])?.let { Routines.Sent(i["kind"].str ?: "routine", i["name"].str ?: "", it) }
                }
                Routines(items, reminders, r["queued"].int ?: 0, recent, r["overrides"].bool ?: false)
            }
            val apps = o["apps"].obj?.let { a ->
                val jobs = (a["jobs"].arr ?: emptyArray).mapNotNull { v ->
                    val j = v.obj ?: return@mapNotNull null
                    val id = j["id"].str ?: return@mapNotNull null
                    val bundleId = j["bundleId"].str ?: ""
                    Apps.Job(id, j["name"].str ?: bundleId, bundleId, j["state"].str ?: "unknown", date(j["created"]),
                        j["version"].str, j["source"].str, date(j["finished"]), j["seconds"].num, j["network"].str,
                        j["message"].str)
                }
                val previous = a["previousSeconds"].num?.let { if (kotlin.math.abs(it) < 1e9) Math.round(it).toInt() else null }
                Apps(a["state"].str ?: "unknown", date(a["since"]), a["network"].str, a["device"].str, previous, jobs)
            }
            return MacStatus(power, display, awake, workspace, session, newChats, kept, bitwarden, routines, apps)
        }
    }
}

/** The Mac's actions that make sense now: the Overview offers only these. */
data class MacOffer(val sleep: Boolean = false, val displayOff: Boolean = false, val displayOn: Boolean = false) {
    companion object {
        /** `features`: what aOS on the Mac knows (hello); `sleeping`: it was put to sleep and hasn't answered since. */
        fun now(status: MacStatus, features: Set<String>, sleeping: Boolean): MacOffer {
            if (sleeping) return MacOffer()
            return when (status.display?.state) {
                "on" -> MacOffer(sleep = true, displayOff = true)
                // Off: aOS wakes it (as a key press would); an older aOS can't.
                "off" -> MacOffer(sleep = true, displayOn = MacAction.DISPLAY_ON.raw in features)
                // No screen to turn on or off (the lid is closed, no monitor).
                "none" -> MacOffer(sleep = true)
                // An older aOS doesn't say: as before.
                else -> MacOffer(sleep = true, displayOff = true)
            }
        }
    }
}

/** What an Overview action brought back. */
data class MacActionResult(
    val status: MacStatus? = null,
    /** mac.sleep: the Mac goes to sleep in this many seconds. */
    val sleepsIn: Double? = null,
    /** The chats ops: the list as it is now. */
    val chats: ChatList? = null,
    /** workspace.sign-out: "done", or "atNextStart" (the workspace was closed). */
    val signOut: String? = null,
) {
    companion object {
        fun from(r: CompanionResponse) = MacActionResult(
            status = r.body["status"].obj?.let(MacStatus::from),
            sleepsIn = if (r.body["sleeping"].bool == true) r.body["after"].num ?: 0.0 else null,
            chats = r.body["chats"].obj?.let(ChatList::from),
            signOut = r.body["signOut"].str,
        )
    }
}

/** The Mac said no to an Overview action; `code` says why (the phone words it). */
class MacRefusal(val code: String?, override val message: String) : Exception(message) {
    /** In English where the code is known, else what the Mac said. The UI maps `code` to its own strings. */
    val text: String
        get() = when (code) {
            "other-service" -> "Another service takes care of sleep on this Mac. aOS leaves it alone."
            "sleep-disabled" -> "Sleep is switched off on this Mac by another program (pmset disablesleep). aOS doesn't change that."
            "sleep-held" -> "aOS's helper didn't let go of the Mac in time. Try again in a moment."
            "not-set-up" -> "The workspace isn't set up yet. Finish the setup in aOS on the Mac."
            "no-session" -> "aOS's background process isn't running on the Mac, so there is no Claude Code session to restart."
            "no-keeper" -> "aOS's background process on the Mac doesn't keep chats reachable right now."
            "keeper-old" -> "aOS's background process on the Mac is older and can't restart a single chat yet. It can after the Mac restarts."
            "not-kept" -> "aOS doesn't run this chat on the Mac right now, so there is nothing to restart."
            "chat-running" -> "Stop it first, or close it in the Claude app."
            "not-found" -> "This chat isn't on the Mac any more."
            "sign-out-failed" -> "Signing out didn't work. The workspace tries again when it starts next."
            else -> message.ifEmpty { "aOS on the Mac said no." }
        }

    override fun equals(other: Any?) = other is MacRefusal && other.code == code && other.message == message
    override fun hashCode() = (code to message).hashCode()
    override fun toString() = "MacRefusal(code=$code, message=$message)"
}

/**
 * A start or close of the workspace asked for from this phone, until the Mac reports it done. aOS on the Mac answers
 * `workspace.start` and `workspace.stop` at once, with the state before, so an answer or a status that still says the
 * old state is no result: the phone keeps showing the operation until the state it asked for comes, the workspace
 * fails, or the time is up.
 */
data class WorkspaceOperation(
    val kind: Kind,
    /** The state when it was asked for (null: not known). */
    val from: String?,
    val since: Instant = Instant.now(),
    /** The Mac reported another state since: a `failed` now is this operation's result, not the one before. */
    val moved: Boolean = false,
) {
    enum class Kind { START, STOP }
    enum class Outcome { UNDER_WAY, DONE, FAILED, TIMED_OUT }

    /** How long the Mac may take, in seconds. */
    val timeoutSeconds: Long get() = if (kind == Kind.START) 5 * 60 else 3 * 60

    /** What the state shows while it is under way. */
    val shownState: String get() = if (kind == Kind.START) "starting" else "closing"

    /** The workspace is where this operation wanted it. */
    fun arrived(state: String?): Boolean = when (kind) {
        Kind.START -> state == "running" || state == "open"
        Kind.STOP -> state == "stopped"
    }

    /** Takes the state the Mac reports now into account: the outcome and the operation as it is afterwards. */
    fun observe(state: String?, now: Instant = Instant.now()): Pair<Outcome, WorkspaceOperation> {
        val next = if (state != null && state != from) copy(moved = true) else this
        if (arrived(state)) return Outcome.DONE to next
        if (state == "failed" && next.moved) {
            // A close is over too: the workspace doesn't run (the card shows the Mac's error).
            return (if (kind == Kind.START) Outcome.FAILED else Outcome.DONE) to next
        }
        val elapsed = now.epochSecond - since.epochSecond
        return (if (elapsed >= timeoutSeconds) Outcome.TIMED_OUT else Outcome.UNDER_WAY) to next
    }

    /** What the person reads when it took too long (English; the UI has its own strings). */
    val timeoutText: String
        get() = if (kind == Kind.START) "The workspace didn't start within 5 minutes. Look at aOS on the Mac."
        else "The workspace didn't close within 3 minutes. Look at aOS on the Mac."

    companion object {
        /** The operation an action starts, if it is one. */
        fun of(action: MacAction, from: String?, since: Instant = Instant.now()): WorkspaceOperation? = when (action) {
            MacAction.WORKSPACE_START -> WorkspaceOperation(Kind.START, from, since)
            MacAction.WORKSPACE_STOP -> WorkspaceOperation(Kind.STOP, from, since)
            else -> null
        }
    }
}
