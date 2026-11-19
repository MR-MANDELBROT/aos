package dev.marquart.aos.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import java.time.Instant

// The chats (Docs/COMPANION.md, "Chats"): the Claude Code conversations as the Mac's settings list them, in the Mac's
// order, with what aOS's keeper does with each. Read with `chats.list`, changed with one signed op per action (the
// chat's id is the signed value). iOS Sources/Core/Chats.swift.

/** The chats as the Mac reports them. Fields a Mac leaves out keep their defaults. */
data class ChatList(
    /** Keeping chats reachable is on (Settings > Claude Code on the Mac). */
    val enabled: Boolean = true,
    /** Besides pinned ones, the ones used within `hours` (else pinned ones only). */
    val automatic: Boolean = true,
    /** Also chats started in a terminal. */
    val terminal: Boolean = false,
    val hours: Int = 48,
    /** At most this many at once. */
    val max: Int = 6,
    /** Running now (the keeper's count). */
    val running: Int = 0,
    /** The keeper on the Mac can restart a single chat. */
    val canRestart: Boolean = false,
    /** In the Mac's order, as it sent them. */
    val chats: List<Chat> = emptyList(),
) {
    data class Chat(
        val id: String,
        val title: String,
        /** Where it runs, with the home folder as "~". */
        val folder: String = "",
        /** app (started in the Claude app), terminal, other. */
        val origin: String? = null,
        /** When the person last wrote in it or got an answer. */
        val activity: Instant? = null,
        val pinned: Boolean = false,
        val skipped: Boolean = false,
        /** running, starting, openElsewhere, waitingForNetwork, needsAttention, failed, folderMissing; null when the
         *  keeper doesn't keep it. */
        val state: String? = null,
        val detail: String? = null,
        /** The detail as a code: app, terminal, elsewhere, signIn, question, exiting, restarting. */
        val note: String? = null,
        val since: Instant? = null,
        /** Why it isn't kept: off, skipped, archived, scheduled, remoteControlOff, ownSession, automation, onlyPinned,
         *  terminal, noRemoteControl, inactive, overLimit. */
        val reason: String? = null,
    ) {
        /** aOS runs it on the Mac now (or starts it). */
        val isRunning: Boolean get() = state == "running" || state == "starting"

        /** It can be continued in the Claude app now. */
        val isReachable: Boolean get() = isRunning || state == "openElsewhere"

        /** aOS keeps it: its keeper has it, or it is pinned, or the rules keep it (no reason given). */
        val isKept: Boolean get() = state != null || (!skipped && (pinned || reason == null))

        /** Nothing runs it on the Mac; only then can it be deleted. A state the phone doesn't know counts as running. */
        val isIdle: Boolean get() = state?.let { it in listOf("failed", "folderMissing", "waitingForNetwork") } ?: true

        /** The Claude app's own choices, aOS's own session and automation: aOS never keeps these. */
        val isNeverKept: Boolean
            get() = (reason ?: "") in listOf("archived", "scheduled", "remoteControlOff", "ownSession", "automation")

        /** The folder's own name. */
        val folderName: String
            get() = folder.split('/').lastOrNull { it.isNotEmpty() }?.takeIf { it.isNotEmpty() } ?: folder
    }

    /** Reachable in the Claude app now (running, starting or open elsewhere). */
    val reachable: Int get() = chats.count { it.isReachable }

    companion object {
        fun from(o: JsonObject): ChatList = ChatList(
            enabled = o["enabled"].bool ?: false,
            automatic = o["automatic"].bool ?: true,
            terminal = o["terminal"].bool ?: false,
            hours = o["hours"].int ?: 48,
            max = o["max"].int ?: 6,
            running = o["running"].int ?: 0,
            canRestart = o["restart"].bool ?: false,
            chats = (o["list"].arr ?: JsonArray(emptyList())).mapNotNull { v ->
                val c = v.obj ?: return@mapNotNull null
                val id = c["id"].str?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                Chat(id, c["title"].str ?: "Claude Code", c["folder"].str ?: "", c["origin"].str,
                    c["activity"].str?.let(Iso8601::parse), c["pinned"].bool ?: false, c["skipped"].bool ?: false,
                    c["state"].str, c["detail"].str, c["note"].str, c["since"].str?.let(Iso8601::parse), c["reason"].str)
            },
        )
    }
}

/** What can be done with a chat now: the Chats page offers only these. */
data class ChatOffer(
    /** `chats.start`, or `chats.pin` on a Mac from before it. */
    val start: MacAction? = null,
    /** `chats.stop`, or `chats.skip` on a Mac from before it. */
    val stop: MacAction? = null,
    val restart: Boolean = false,
    /** Its conversation to the Mac's Trash: only while nothing runs it, and only a Mac that knows `chats.delete`. */
    val delete: Boolean = false,
) {
    val isEmpty: Boolean get() = this == ChatOffer()

    companion object {
        /** `features`: what aOS on the Mac knows (hello). */
        fun now(chat: ChatList.Chat, list: ChatList, features: Set<String>): ChatOffer {
            fun has(action: MacAction) = action.raw in features
            val restart = has(MacAction.CHATS_RESTART) && list.enabled && list.canRestart &&
                (chat.state ?: "") in listOf("running", "starting", "needsAttention", "failed")
            var start: MacAction? = null
            if (!chat.isReachable && !chat.isNeverKept && list.enabled && !restart && chat.state != "folderMissing") {
                start = if (has(MacAction.CHATS_START)) MacAction.CHATS_START else if (has(MacAction.CHATS_PIN)) MacAction.CHATS_PIN else null
            }
            val stop = if (chat.isKept) {
                if (has(MacAction.CHATS_STOP)) MacAction.CHATS_STOP else if (has(MacAction.CHATS_SKIP)) MacAction.CHATS_SKIP else null
            } else null
            val delete = has(MacAction.CHATS_DELETE) && chat.isIdle && chat.reason != "ownSession"
            return ChatOffer(start, stop, restart, delete)
        }
    }
}
