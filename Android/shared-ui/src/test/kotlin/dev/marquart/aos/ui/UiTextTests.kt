package dev.marquart.aos.ui

import dev.marquart.aos.R
import dev.marquart.aos.companion.CompanionError
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.BitwardenLogin
import dev.marquart.aos.core.BitwardenState
import dev.marquart.aos.core.ChatList
import dev.marquart.aos.core.ChatOffer
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.MacRefusal
import dev.marquart.aos.core.MacStatus
import dev.marquart.aos.core.MacStayAwake
import dev.marquart.aos.core.PairingLink
import dev.marquart.aos.core.SignInRequest
import dev.marquart.aos.ssh.PairingClient
import dev.marquart.aos.ui.Txt.Companion.plural
import dev.marquart.aos.ui.Txt.Companion.raw
import dev.marquart.aos.ui.Txt.Companion.res
import dev.marquart.aos.ui.overview.AosText
import dev.marquart.aos.ui.overview.AppsText
import dev.marquart.aos.ui.overview.ChatCommand
import dev.marquart.aos.ui.overview.ChatQuestion
import dev.marquart.aos.ui.overview.ChatsText
import dev.marquart.aos.ui.overview.MacStatusText
import dev.marquart.aos.ui.overview.RoutineSetupText
import dev.marquart.aos.ui.overview.WorkspaceText
import dev.marquart.aos.ui.overview.chatCommands
import dev.marquart.aos.ui.pairing.PairingStep
import dev.marquart.aos.ui.pairing.acceptPairingText
import dev.marquart.aos.ui.signin.BitwardenNotice
import dev.marquart.aos.ui.signin.bitwardenNotice
import dev.marquart.aos.ui.tailnet.TailnetInfo
import org.junit.Test
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull

/** The UI's words: which text each state gets (the views only show them). */
class UiTextTests {
    private fun power(battery: Int? = 76, charging: Boolean? = false, source: String = "battery", minutes: Int? = 312,
                      lid: String = "open", thermal: String = "nominal") = MacStatus.Power(source, battery, charging, minutes, lid, thermal)

    @Test fun batteryCaptionSaysWhatThePowerDoes() {
        assertEquals(res(R.string.mac_time_left, "5:12"), MacStatusText.batteryCaption(power()))
        assertEquals(res(R.string.mac_on_battery), MacStatusText.batteryCaption(power(minutes = null)))
        assertEquals(res(R.string.mac_charging), MacStatusText.batteryCaption(power(charging = true, source = "ac")))
        assertEquals(res(R.string.mac_plugged_in), MacStatusText.batteryCaption(power(source = "ac")))
        assertEquals(res(R.string.mac_plugged_in), MacStatusText.batteryCaption(power(battery = null, source = "ac")))
        assertEquals(res(R.string.mac_power), MacStatusText.batteryValue(power(battery = null)))
        assertEquals(res(R.string.percent, 76), MacStatusText.batteryValue(power()))
    }

    @Test fun thermalAndLid() {
        assertNull(MacStatusText.thermalShort(power()))
        assertEquals(res(R.string.mac_very_warm), MacStatusText.thermalShort(power(thermal = "serious")))
        assertEquals(res(R.string.mac_too_hot), MacStatusText.thermalShort(power(thermal = "critical")))
        assertEquals(res(R.string.mac_lid_closed), MacStatusText.lidTitle(power(lid = "closed")))
        assertEquals(res(R.string.mac_no_lid), MacStatusText.lidTitle(power(lid = "none")))
    }

    @Test fun displayCaptionCountsMonitors() {
        assertEquals(res(R.string.mac_no_monitor), MacStatusText.displayCaption(MacStatus.Display("none", 0)))
        assertEquals(res(R.string.mac_built_in_only), MacStatusText.displayCaption(MacStatus.Display("on", 0)))
        assertEquals(plural(R.plurals.mac_monitors, 2), MacStatusText.displayCaption(MacStatus.Display("on", 2)))
    }

    @Test fun stayingAwakeSaysWhyNot() {
        fun awake(setting: MacStayAwake = MacStayAwake.LID_CLOSED, holding: Boolean = true, lidClosed: Boolean = false,
                  blocker: String? = null, helper: String = "enabled", other: Boolean = false) =
            MacStatus.Awake(setting, holding, lidClosed, blocker, helper, other)
        assertEquals(res(R.string.mac_awake_other_service), MacStatusText.awakeDetail(awake(other = true, blocker = "lowBattery")))
        assertEquals(res(R.string.mac_awake_low_battery), MacStatusText.awakeDetail(awake(blocker = "lowBattery")))
        assertEquals(res(R.string.mac_awake_allow_helper), MacStatusText.awakeDetail(awake(blocker = "helperNotReady", helper = "requiresApproval")))
        assertEquals(res(R.string.mac_awake_helper_not_set_up), MacStatusText.awakeDetail(awake(blocker = "helperNotReady")))
        assertEquals(res(R.string.mac_awake_detail_ready), MacStatusText.awakeDetail(awake()))
        assertEquals(res(R.string.mac_awake_detail_lid_closed_now), MacStatusText.awakeDetail(awake(lidClosed = true)))
        assertEquals(res(R.string.mac_awake_detail_lid_closed), MacStatusText.awakeDetail(awake(holding = false)))
        assertEquals(res(R.string.mac_awake_detail_off), MacStatusText.awakeDetail(awake(MacStayAwake.OFF)))
        assertEquals(true, MacStatusText.awakeWarns(awake(blocker = "thermal")))
        assertEquals(false, MacStatusText.awakeWarns(awake(blocker = "nothingToKeep")))
        assertEquals(res(R.string.mac_no_limit), MacStatusText.batteryLimitName(0))
    }

    @Test fun hostsInWords() {
        assertEquals(res(R.string.mac_via_network, "Mac.local"), MacStatusText.describeHost("Mac.local"))
        assertEquals(res(R.string.mac_via_tailscale, "mac.tail4c2a.ts.net"), MacStatusText.describeHost("mac.tail4c2a.ts.net"))
        assertEquals(res(R.string.mac_via_tailscale, "100.101.7.12"), MacStatusText.describeHost("100.101.7.12"))
        assertEquals(raw("192.168.1.2"), MacStatusText.describeHost("192.168.1.2"))
    }

    @Test fun workspaceState() {
        assertEquals(res(R.string.workspace_no_news), WorkspaceText.state("open", live = false, known = true, setupComplete = true))
        assertEquals(res(R.string.workspace_no_news), WorkspaceText.state("open", live = true, known = false, setupComplete = true))
        assertEquals(res(R.string.workspace_not_set_up), WorkspaceText.state("stopped", true, true, false))
        assertEquals(res(R.string.workspace_open), WorkspaceText.state("open", true, true, true))
        assertEquals(res(R.string.workspace_running), WorkspaceText.state("running", true, true, null))
        assertEquals(res(R.string.closing), WorkspaceText.state("closing", true, true, true))
        assertEquals(raw("paused"), WorkspaceText.state("paused", true, true, true))
        assertEquals(res(R.string.waiting_for_you), WorkspaceText.sessionState("asking"))
    }

    @Test fun sessionAndSignIn() {
        assertEquals(res(R.string.session_off), AosText.session(MacStatus.Session(false, "running")))
        assertEquals(res(R.string.needs_claude_sign_in), AosText.session(MacStatus.Session(true, "needsLogin")))
        assertEquals(res(R.string.session_not_set_up), AosText.session(MacStatus.Session(true, null)))
        assertEquals(true, AosText.sessionWarns(MacStatus.Session(true, "missingClaude")))
        val needsLogin = MacStatus(newChats = MacStatus.NewChats(true, "needsLogin"))
        assertEquals(true, AosText.needsSignIn(needsLogin))
        assertEquals(false, AosText.needsSignIn(MacStatus(newChats = MacStatus.NewChats(false, "needsLogin"))))
        assertEquals(false, AosText.needsSignIn(null))
        assertEquals(res(R.string.vault_locked), AosText.vault(MacStatus.Vault("locked")))
        assertEquals(res(R.string.checking), AosText.vault(MacStatus.Vault("unknown")))
    }

    @Test fun routinesRowNamesTheNextOne() {
        val at = Instant.parse("2026-11-20T07:30:00Z")
        val routines = MacStatus.Routines(listOf(
            MacStatus.Routines.Item("a", "Later", "0 9 * * *", "", true, at.plusSeconds(3600)),
            MacStatus.Routines.Item("b", "Briefing", "30 7 * * *", "", true, at),
            MacStatus.Routines.Item("c", "Off", "0 6 * * *", "", false, at.minusSeconds(3600)),
        ))
        assertEquals(res(R.string.routines_next, "Briefing", Txt.Time(at, Txt.TimeStyle.TIME_OR_WEEKDAY)), AosText.routines(routines))
        assertEquals(res(R.string.routines_all_off), AosText.routines(MacStatus.Routines(emptyList())))
    }

    @Test fun aRoutinesOwnModelAndEffort() {
        val plain = MacStatus.Routines.Item("a", "Check", "0 9 * * *", "", true)
        assertEquals(null, RoutineSetupText.setup(plain))
        assertEquals(Txt.raw("Sonnet"), RoutineSetupText.setup(plain.copy(model = "sonnet")))
        assertEquals(res(R.string.routine_setup_effort, res(R.string.routine_effort_low)), RoutineSetupText.setup(plain.copy(effort = "low")))
        assertEquals(res(R.string.routine_setup_both, res(R.string.routine_model_opus_1m), res(R.string.routine_effort_xhigh)),
            RoutineSetupText.setup(plain.copy(model = "opus[1m]", effort = "xhigh")))
        assertEquals("claude-opus-5-5", RoutineSetupText.models("claude-opus-5-5").last())
        assertEquals(MacStatus.Routines.Item.models, RoutineSetupText.models("haiku"))
    }

    private val list = ChatList(enabled = true, hours = 48, max = 6, canRestart = true, chats = listOf(
        ChatList.Chat("1", "Running", state = "running"),
        ChatList.Chat("2", "Elsewhere", state = "openElsewhere", note = "app"),
        ChatList.Chat("3", "Old", reason = "inactive"),
        ChatList.Chat("4", "Stopped", skipped = true, reason = "skipped"),
    ))

    @Test fun chatsSummaryAndStates() {
        assertEquals(plural(R.plurals.chats_reachable, 2), ChatsText.summary(list))
        assertEquals(res(R.string.chats_off_on_mac), ChatsText.summary(list.copy(enabled = false)))
        assertEquals(res(R.string.chats_none_reachable_now), ChatsText.summary(list.copy(chats = list.chats.drop(2))))
        assertEquals(res(R.string.chat_reachable), ChatsText.state(list.chats[0], list))
        assertEquals(res(R.string.chat_open_in_app), ChatsText.state(list.chats[1], list))
        assertEquals(res(R.string.chat_inactive, 48), ChatsText.state(list.chats[2], list))
        assertEquals(res(R.string.stopped), ChatsText.state(list.chats[3], list))
        assertEquals(res(R.string.chat_explain_not_kept, 6), ChatsText.explanation(list.chats[2], list))
        assertEquals(ChatsText.Tint.GREEN, ChatsText.tint(list.chats[0]))
        assertEquals(ChatsText.Tint.GRAY, ChatsText.tint(list.chats[3]))
    }

    @Test fun chatsOverviewRowHasALinePerFact() {
        val text = ChatsText.overview(list, MacStatus.NewChats(true, "needsLogin"), kept = 5)
        assertEquals(Txt.Join(listOf(plural(R.plurals.chats_reachable_short, 2), res(R.string.new_chats_need_sign_in)), "\n"), text)
        // Without the list, the status's count.
        assertEquals(Txt.Join(listOf(res(R.string.chats_none_reachable_short)), "\n"), ChatsText.overview(null, null, kept = 0))
    }

    @Test fun chatActionsAskFirstExceptStart() {
        val features = setOf("chats.list", "chats.start", "chats.stop", "chats.restart", "chats.delete")
        val offer = ChatOffer.now(list.chats[2], list, features)
        val commands = chatCommands(offer).map { it.first }
        assertEquals(listOf<ChatCommand>(ChatCommand.Start(MacAction.CHATS_START), ChatCommand.Delete), commands)
        assertNull(ChatQuestion.of(ChatCommand.Start(MacAction.CHATS_START), list.chats[2]))
        assertEquals(MacAction.CHATS_DELETE, ChatQuestion.of(ChatCommand.Delete, list.chats[2])!!.action)
        val running = chatCommands(ChatOffer.now(list.chats[0], list, features)).map { it.first }
        assertEquals(listOf(ChatCommand.Restart, ChatCommand.Stop(MacAction.CHATS_STOP)), running)
    }

    @Test fun appsOnThePhone() {
        val job = MacStatus.Apps.Job("1", "aOS", "dev.marquart.aos", "installing")
        val apps = MacStatus.Apps("connected", network = "wifi", jobs = listOf(job, job.copy(id = "2", state = "queued")))
        assertEquals(Txt.Join(listOf(res(R.string.apps_connected_wifi), plural(R.plurals.apps_installing, 2)), "\n"), AppsText.overview(apps))
        assertEquals(plural(R.plurals.apps_waiting, 1), AppsText.pendingShort(apps.copy(jobs = listOf(job.copy(state = "queued")))))
        assertNull(AppsText.pendingShort(apps.copy(jobs = emptyList())))
        assertEquals(res(R.string.apps_waiting_wifi), AppsText.connectionShort(MacStatus.Apps("searching")))
        assertEquals(Txt.Join(listOf(res(R.string.unit_hours, 1), res(R.string.unit_minutes, 10)), " "), AppsText.duration(4210))
        assertEquals(Txt.Join(listOf(res(R.string.unit_minutes, 4), res(R.string.unit_seconds, 30)), " "), AppsText.duration(270))
        assertEquals(Txt.Join(listOf(res(R.string.unit_seconds, 0)), " "), AppsText.duration(0))
        assertEquals(Txt.Join(listOf(raw("dev.marquart.aos"), res(R.string.seconds_short, 28), res(R.string.apps_on_cellular)), " · "),
            AppsText.detail(job.copy(seconds = 28.4, network = "cellular")))
    }

    @Test fun errorsInTheAppsWords() {
        assertEquals(res(R.string.refusal_sleep_disabled), ErrorText.of(MacRefusal("sleep-disabled", "x")))
        assertEquals(raw("The Mac said no."), ErrorText.of(MacRefusal("new-code", "The Mac said no.")))
        assertEquals(res(R.string.error_timeout), ErrorText.of(CompanionError.Timeout))
        assertEquals(res(R.string.refusal_no_session), ErrorText.of(CompanionError.Refused("x", "no-session")))
        assertEquals(res(R.string.pair_error_no_answer), ErrorText.of(PairingClient.Failure.NoAnswer))
        assertEquals(res(R.string.pair_error_refused, "busy"), ErrorText.of(PairingClient.Failure.Refused("busy")))
        assertEquals(res(R.string.pair_newer_code), ErrorText.of(PairingLink.ParseError.NewerVersion))
    }

    @Test fun connectionMessagesAreWorded() {
        assertEquals(res(R.string.conn_going_to_sleep), ConnectionText.message("The Mac is going to sleep."))
        assertEquals(res(R.string.conn_host_key_changed, "Mac.local"), ConnectionText.message(
            "At Mac.local a different computer answered, or the Mac's SSH key changed. If you set the Mac up again, pair it again."))
        assertEquals(res(R.string.conn_companion_silent), ConnectionText.message(MacConnection.companionMessage(CompanionError.Timeout)))
        assertEquals(res(R.string.conn_companion_not_ready, "boom"), ConnectionText.message("aOS on the Mac isn't ready: boom"))
        assertEquals(raw("Something new"), ConnectionText.message("Something new"))
    }

    @Test fun pairingTextIsChecked() {
        val link = PairingLink("Mac", listOf("Mac.local"), 50123, 22, "max", "SHA256:IKIpT5qrBHciGB6LMk+7fuTQHDnNluSkoLBSGY4SWMQ", ByteArray(16))
        assertIs<PairingStep.Confirm>(acceptPairingText(link.url).first)
        assertEquals(null to R.string.pair_newer_code, acceptPairingText("aos-pair://v2?n=Mac"))
        assertEquals(null to R.string.pair_not_a_code, acceptPairingText("https://example.com"))
    }

    @Test fun bitwardenNotices() {
        val login = BitwardenLogin("1", "GitHub", "max", hasCode = false)
        fun request(state: BitwardenState, field: SignInRequest.Field = SignInRequest.Field.PASSWORD, logins: List<BitwardenLogin> = emptyList()) =
            SignInRequest("r", "Claude", "github.com", "", field = field, logins = logins, bitwarden = state)
        assertEquals(BitwardenNotice.LOCKED, bitwardenNotice(request(BitwardenState.LOCKED)))
        assertEquals(BitwardenNotice.NO_LOGIN, bitwardenNotice(request(BitwardenState.UNLOCKED)))
        assertNull(bitwardenNotice(request(BitwardenState.UNLOCKED, logins = listOf(login))))
        // A code needs a login with an authenticator key.
        assertEquals(BitwardenNotice.NO_LOGIN, bitwardenNotice(request(BitwardenState.UNLOCKED, SignInRequest.Field.CODE, listOf(login))))
        assertNull(bitwardenNotice(request(BitwardenState.OFF)))
    }

    @Test fun onlyTailscalesPagesOpen() {
        assertEquals("https://login.tailscale.com/a/abc", TailnetInfo.signInPage("https://login.tailscale.com/a/abc"))
        assertNull(TailnetInfo.signInPage("http://login.tailscale.com/a/abc"))
        assertNull(TailnetInfo.signInPage("https://tailscale.com.evil.example/a"))
        assertNull(TailnetInfo.signInPage(""))
        assertEquals(listOf("100.1.2.3", "fd7a::1"), TailnetInfo.addresses("100.1.2.3, fd7a::1"))
    }
}
