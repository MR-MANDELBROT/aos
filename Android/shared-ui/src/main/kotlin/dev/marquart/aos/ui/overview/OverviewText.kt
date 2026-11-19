package dev.marquart.aos.ui.overview

import dev.marquart.aos.R
import dev.marquart.aos.core.ChatList
import dev.marquart.aos.core.MacStatus
import dev.marquart.aos.core.MacStayAwake
import dev.marquart.aos.ui.Txt
import dev.marquart.aos.ui.Txt.Companion.plural
import dev.marquart.aos.ui.Txt.Companion.raw
import dev.marquart.aos.ui.Txt.Companion.res
import java.time.Instant

// The Overview's words, kept apart from the views for the tests (iOS MacStatusText, AOSCard's, ChatsText, AppsText).

/** The Mac's status in words. */
object MacStatusText {
    fun clock(minutes: Int): String = "%d:%02d".format(minutes / 60, minutes % 60)

    fun batteryLimitName(percent: Int): Txt = if (percent == 0) res(R.string.mac_no_limit) else res(R.string.percent, percent)

    fun batteryLimitDetail(percent: Int): Txt =
        if (percent == 0) res(R.string.mac_battery_limit_none) else res(R.string.mac_battery_limit_some)

    fun batteryValue(p: MacStatus.Power): Txt = p.battery?.let { res(R.string.percent, it) } ?: res(R.string.mac_power)

    fun batteryCaption(p: MacStatus.Power): Txt {
        if (p.battery == null) return res(R.string.mac_plugged_in)
        if (p.charging == true) return res(R.string.mac_charging)
        if (p.source == "battery") return p.minutes?.let { res(R.string.mac_time_left, clock(it)) } ?: res(R.string.mac_on_battery)
        return res(R.string.mac_plugged_in)
    }

    fun thermalShort(p: MacStatus.Power): Txt? = when (p.thermal) {
        "serious" -> res(R.string.mac_very_warm)
        "critical" -> res(R.string.mac_too_hot)
        else -> null
    }

    fun isHot(p: MacStatus.Power) = p.thermal == "serious" || p.thermal == "critical"

    fun lidTitle(p: MacStatus.Power): Txt = when (p.lid) {
        "closed" -> res(R.string.mac_lid_closed)
        "open" -> res(R.string.mac_lid_open)
        else -> res(R.string.mac_no_lid)
    }

    fun displayTitle(d: MacStatus.Display): Txt = when (d.state) {
        "on" -> res(R.string.mac_display_on)
        "off" -> res(R.string.mac_display_off)
        else -> res(R.string.mac_no_display)
    }

    fun displayCaption(d: MacStatus.Display): Txt {
        if (d.state == "none") return res(R.string.mac_no_monitor)
        return when (d.external) {
            0 -> res(R.string.mac_built_in_only)
            else -> plural(R.plurals.mac_monitors, d.external)
        }
    }

    fun stayAwakeName(mode: MacStayAwake): Txt = when (mode) {
        MacStayAwake.OFF -> res(R.string.off)
        MacStayAwake.LID_OPEN -> res(R.string.mac_awake_lid_open_long)
        MacStayAwake.LID_CLOSED -> res(R.string.mac_awake_lid_closed_long)
    }

    fun stayAwakeShortName(mode: MacStayAwake): Txt = when (mode) {
        MacStayAwake.OFF -> res(R.string.off)
        MacStayAwake.LID_OPEN -> res(R.string.mac_awake_lid_open)
        MacStayAwake.LID_CLOSED -> res(R.string.mac_awake_lid_closed)
    }

    fun awakeWarns(a: MacStatus.Awake) = a.blocker == "lowBattery" || a.blocker == "thermal" || a.blocker == "helperNotReady"

    fun awakeDetail(a: MacStatus.Awake): Txt {
        if (a.otherService) return res(R.string.mac_awake_other_service)
        when (a.blocker) {
            "lowBattery" -> return res(R.string.mac_awake_low_battery)
            "thermal" -> return res(R.string.mac_awake_thermal)
            "nothingToKeep" -> return res(R.string.mac_awake_nothing_to_keep)
            "helperNotReady" -> return if (a.helper == "requiresApproval") res(R.string.mac_awake_allow_helper)
                else res(R.string.mac_awake_helper_not_set_up)
        }
        return when (a.setting) {
            MacStayAwake.OFF -> res(R.string.mac_awake_detail_off)
            MacStayAwake.LID_OPEN -> res(R.string.mac_awake_detail_lid_open)
            MacStayAwake.LID_CLOSED -> when {
                a.lidClosedMode -> res(R.string.mac_awake_detail_lid_closed_now)
                a.holding -> res(R.string.mac_awake_detail_ready)
                else -> res(R.string.mac_awake_detail_lid_closed)
            }
        }
    }

    /** How the Mac is reached, in words: the local network, Tailscale, or an address. */
    fun describeHost(host: String): Txt {
        val lower = host.lowercase()
        if (lower.endsWith(".ts.net") || lower.startsWith("100.")) return res(R.string.mac_via_tailscale, host)
        if (lower.endsWith(".local")) return res(R.string.mac_via_network, host)
        return raw(host)
    }
}

/** The workspace card's words. */
object WorkspaceText {
    fun sessionState(state: String): Txt = when (state) {
        "running" -> res(R.string.running)
        "starting" -> res(R.string.starting)
        "stopped" -> res(R.string.stopped)
        "waiting", "asking" -> res(R.string.waiting_for_you)
        "failed" -> res(R.string.failed)
        else -> raw(state)
    }

    /** `live`: aOS on the Mac answers; `known`: it reported the workspace. */
    fun state(state: String, live: Boolean, known: Boolean, setupComplete: Boolean?): Txt {
        if (!live || !known) return res(R.string.workspace_no_news)
        if (setupComplete == false) return res(R.string.workspace_not_set_up)
        return when (state) {
            "stopped" -> res(R.string.workspace_closed)
            "starting" -> res(R.string.starting)
            "open" -> res(R.string.workspace_open)
            "running" -> res(R.string.workspace_running)
            "closing" -> res(R.string.closing)
            "failed" -> res(R.string.workspace_failed)
            else -> raw(state)
        }
    }
}

/** The aOS card's words. */
object AosText {
    fun sessionWarns(s: MacStatus.Session) = (s.state ?: "") in listOf("needsLogin", "needsAttention", "failed", "missingClaude")

    fun session(s: MacStatus.Session): Txt {
        if (!s.enabled) return res(R.string.session_off)
        return when (s.state) {
            "running" -> res(R.string.session_running)
            "starting" -> res(R.string.starting)
            "restarting" -> res(R.string.restarting)
            "waitingForNetwork" -> res(R.string.waiting_for_network)
            "needsLogin" -> res(R.string.needs_claude_sign_in)
            "needsAttention" -> res(R.string.session_needs_attention)
            "missingClaude" -> res(R.string.claude_missing)
            "stopped" -> res(R.string.stopped)
            "failed" -> res(R.string.session_failed)
            null -> res(R.string.session_not_set_up)
            else -> raw(s.state ?: "")
        }
    }

    fun routines(r: MacStatus.Routines): Txt {
        val next = r.next ?: return res(R.string.routines_all_off)
        val at = next.next ?: return res(R.string.routines_all_off)
        return res(R.string.routines_next, next.name, Txt.Time(at, Txt.TimeStyle.TIME_OR_WEEKDAY))
    }

    fun newChats(c: MacStatus.NewChats): Txt {
        if (!c.enabled) return res(R.string.off)
        return when (c.state) {
            "running" -> res(R.string.new_chats_running)
            "needsLogin" -> res(R.string.needs_claude_sign_in)
            "needsTrust" -> res(R.string.new_chats_needs_trust)
            "waitingForNetwork" -> res(R.string.waiting_for_network)
            "missingClaude" -> res(R.string.claude_missing)
            else -> res(R.string.starting)
        }
    }

    fun vault(v: MacStatus.Vault): Txt = when (v.state) {
        "unlocked" -> v.until?.let { res(R.string.vault_unlocked_until, Txt.Time(it, Txt.TimeStyle.TIME)) } ?: res(R.string.vault_unlocked)
        "locked" -> res(R.string.vault_locked)
        "needsHelper" -> res(R.string.vault_needs_helper)
        "signedOut" -> res(R.string.vault_signed_out)
        else -> res(R.string.checking)
    }

    /** Claude Code on the Mac waits for a sign-in (the session or new chats say so). */
    fun needsSignIn(status: MacStatus?): Boolean =
        (status?.session?.enabled == true && status.session?.state == "needsLogin") ||
            (status?.newChats?.enabled == true && status.newChats?.state == "needsLogin")

    fun kept(count: Int): Txt = plural(R.plurals.kept_reachable, count)
}

/** The chats in words. */
object ChatsText {
    fun summary(list: ChatList): Txt {
        if (!list.enabled) return res(R.string.chats_off_on_mac)
        return if (list.reachable == 0) res(R.string.chats_none_reachable_now) else plural(R.plurals.chats_reachable, list.reachable)
    }

    fun overview(list: ChatList?, newChats: MacStatus.NewChats?, kept: Int?): Txt {
        val first = when {
            list != null -> if (list.enabled) reachableShort(list.reachable) else res(R.string.chats_keeping_off)
            kept != null -> reachableShort(kept)
            else -> null
        }
        return Txt.lines(first, newChats?.let(::newChatsShort))
    }

    fun reachableShort(count: Int): Txt =
        if (count == 0) res(R.string.chats_none_reachable_short) else plural(R.plurals.chats_reachable_short, count)

    fun newChatsShort(c: MacStatus.NewChats): Txt {
        if (!c.enabled) return res(R.string.new_chats_off)
        return when (c.state) {
            "running" -> res(R.string.new_chats_on)
            "needsLogin" -> res(R.string.new_chats_need_sign_in)
            "needsTrust" -> res(R.string.new_chats_wait_trust)
            "waitingForNetwork" -> res(R.string.new_chats_wait_network)
            "missingClaude" -> res(R.string.claude_missing)
            else -> res(R.string.new_chats_starting)
        }
    }

    enum class Tint { GREEN, INDIGO, YELLOW, ORANGE, GRAY }

    fun tint(chat: ChatList.Chat): Tint = when (chat.state) {
        "running" -> Tint.GREEN
        "openElsewhere" -> Tint.INDIGO
        "starting", "waitingForNetwork" -> Tint.YELLOW
        "needsAttention", "failed", "folderMissing" -> Tint.ORANGE
        else -> Tint.GRAY
    }

    fun state(chat: ChatList.Chat, list: ChatList): Txt {
        val state = chat.state
        if (state != null) {
            return when (state) {
                "running" -> res(R.string.chat_reachable)
                "starting" -> if (chat.note == "restarting") res(R.string.restarting) else res(R.string.starting)
                "openElsewhere" -> when (chat.note) {
                    "app" -> res(R.string.chat_open_in_app)
                    "terminal" -> res(R.string.chat_open_in_terminal)
                    else -> res(R.string.chat_open_elsewhere)
                }
                "waitingForNetwork" -> res(R.string.waiting_for_network)
                "needsAttention" -> when (chat.note) {
                    "signIn" -> res(R.string.chat_needs_sign_in)
                    "question" -> res(R.string.chat_asks)
                    "exiting" -> res(R.string.chat_keeps_stopping)
                    else -> chat.detail?.let(::raw) ?: res(R.string.chat_needs_you)
                }
                "failed" -> chat.detail?.let(::raw) ?: res(R.string.workspace_failed)
                "folderMissing" -> res(R.string.chat_folder_gone)
                else -> raw(chat.detail ?: state)
            }
        }
        return when (chat.reason) {
            "skipped" -> res(R.string.stopped)
            "archived" -> res(R.string.chat_archived)
            "scheduled" -> res(R.string.chat_scheduled)
            "remoteControlOff" -> res(R.string.chat_remote_control_off)
            "ownSession" -> res(R.string.chat_own_session)
            "automation" -> res(R.string.chat_automation)
            "onlyPinned" -> res(R.string.chat_not_pinned)
            "terminal" -> res(R.string.chat_from_terminal)
            "noRemoteControl" -> res(R.string.chat_no_remote_control)
            "inactive" -> res(R.string.chat_inactive, list.hours)
            "overLimit" -> res(R.string.chat_over_limit, list.max)
            "off" -> res(R.string.chats_off_on_mac)
            null -> res(R.string.chat_starting_soon)
            else -> raw(chat.reason ?: "")
        }
    }

    fun explanation(chat: ChatList.Chat, list: ChatList): Txt? = when (chat.state) {
        "running" -> res(R.string.chat_explain_running)
        "openElsewhere" -> if (chat.note == "app") res(R.string.chat_explain_open_app) else res(R.string.chat_explain_open_elsewhere)
        "needsAttention" -> when (chat.note) {
            "signIn" -> res(R.string.chat_explain_sign_in)
            "exiting" -> res(R.string.chat_explain_exiting)
            else -> null
        }
        null -> when (chat.reason) {
            "skipped" -> res(R.string.chat_explain_skipped)
            "inactive", "overLimit", "terminal", "noRemoteControl", "onlyPinned" -> res(R.string.chat_explain_not_kept, list.max)
            else -> null
        }
        else -> null
    }

    fun origin(chat: ChatList.Chat): Txt = when (chat.origin) {
        "app" -> res(R.string.chat_origin_app)
        "terminal" -> res(R.string.chat_origin_terminal)
        else -> res(R.string.elsewhere)
    }

    fun originShort(chat: ChatList.Chat): Txt = when (chat.origin) {
        "app" -> res(R.string.chat_origin_app_short)
        "terminal" -> res(R.string.terminal)
        else -> res(R.string.elsewhere)
    }
}

/** Installing apps on this phone, in words. */
object AppsText {
    fun overview(apps: MacStatus.Apps): Txt = Txt.lines(connectionShort(apps), pendingShort(apps))

    fun connectionShort(apps: MacStatus.Apps): Txt {
        if (!apps.isConnected) return connectionTitle(apps)
        return when (apps.network) {
            "wifi" -> res(R.string.apps_connected_wifi)
            "cellular" -> res(R.string.apps_connected_cellular)
            else -> res(R.string.connected)
        }
    }

    fun connectionTitle(apps: MacStatus.Apps): Txt = when (apps.state) {
        "connected" -> res(R.string.connected)
        "searching", "connecting", "starting" -> res(R.string.apps_waiting_wifi)
        "notPaired" -> res(R.string.apps_not_paired)
        "stopped" -> res(R.string.off)
        else -> res(R.string.apps_state_unknown)
    }

    fun connectionExplanation(apps: MacStatus.Apps): Txt? = when (apps.state) {
        "connected" -> if (apps.network == "cellular") res(R.string.apps_explain_cellular) else null
        "searching", "connecting", "starting" -> res(R.string.apps_explain_waiting)
        "notPaired" -> res(R.string.apps_explain_not_paired)
        "stopped" -> res(R.string.apps_explain_stopped)
        else -> null
    }

    fun pendingShort(apps: MacStatus.Apps): Txt? {
        val count = apps.queued + apps.installing
        if (apps.installing > 0) return plural(R.plurals.apps_installing, count)
        return if (count == 0) null else plural(R.plurals.apps_waiting, count)
    }

    fun networkName(network: String): Txt = when (network) {
        "wifi" -> res(R.string.wifi)
        "cellular" -> res(R.string.cellular)
        else -> raw(network)
    }

    fun state(job: MacStatus.Apps.Job): Txt = when (job.state) {
        "done" -> res(R.string.apps_installed)
        "failed" -> res(R.string.failed)
        "installing" -> res(R.string.apps_installing_state)
        "queued" -> res(R.string.apps_queued)
        else -> raw(job.state)
    }

    fun stateLine(job: MacStatus.Apps.Job): Txt =
        Txt.Join(listOfNotNull(state(job), job.source?.takeIf { it.isNotEmpty() }?.let(::raw)), " · ")

    fun detail(job: MacStatus.Apps.Job): Txt {
        val parts = mutableListOf<Txt>()
        if (job.bundleId.isNotEmpty()) parts += raw(job.bundleId)
        job.seconds?.let { if (it >= 0 && it < 1e6) parts += res(R.string.seconds_short, maxOf(1, Math.round(it).toInt())) }
        if (job.network == "cellular") parts += res(R.string.apps_on_cellular)
        return Txt.Join(parts, " · ")
    }

    /** "1 h 10 min", "4 min 30 s": the two largest units. */
    fun duration(seconds: Int): Txt {
        val s = maxOf(0, seconds)
        val days = s / 86_400; val hours = (s % 86_400) / 3600; val minutes = (s % 3600) / 60; val secs = s % 60
        val parts = mutableListOf<Txt>()
        if (s >= 3600) {
            if (days > 0) parts += res(R.string.unit_days, days)
            if (hours > 0) parts += res(R.string.unit_hours, hours)
            if (minutes > 0 && days == 0) parts += res(R.string.unit_minutes, minutes)
        } else {
            if (minutes > 0) parts += res(R.string.unit_minutes, minutes)
            if (secs > 0 || minutes == 0) parts += res(R.string.unit_seconds, secs)
        }
        return Txt.Join(parts.take(2), " ")
    }

    fun since(at: Instant): Txt = Txt.Time(at, Txt.TimeStyle.TIME_OR_WEEKDAY)
}
