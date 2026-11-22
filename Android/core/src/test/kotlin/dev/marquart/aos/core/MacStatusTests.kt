package dev.marquart.aos.core

import kotlinx.serialization.json.JsonObject
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun obj(json: String): JsonObject = Json.parseObject(json.toByteArray())!!
private fun status(json: String) = MacStatus.from(obj(json))

/** The Overview's ops (iOS MacStatusTests, WorkspaceOperationTests, ChatsTests, AppsTests, RoutinesTests). */
class MacStatusTests {
    @Test fun whatTheOpsSign() {
        val sleep = CompanionRequest.Mac(MacAction.SLEEP).signatureFields("k", 1, "n")
        assertEquals("companion.mac.sleep", sleep.op)
        assertEquals(CompanionSignature.dataDigest(), sleep.data)
        val awake = CompanionRequest.Mac(MacAction.STAY_AWAKE, "lidClosed").signatureFields("k", 1, "n")
        assertEquals("companion.mac.stay-awake", awake.op)
        assertEquals(CompanionSignature.dataDigest(text = "lidClosed"), awake.data)
        assertEquals("workspace.start", CompanionRequest.Mac(MacAction.WORKSPACE_START).op)
    }

    @Test fun theLineCarriesTheValueAsText() {
        val o = Json.parseObject(CompanionRequest.Mac(MacAction.STAY_AWAKE, "off").line(4))!!
        assertEquals("mac.stay-awake", o["op"].str)
        assertEquals("off", o["text"].str)
        assertNull(Json.parseObject(CompanionRequest.Mac(MacAction.SLEEP).line(5))!!["text"])
    }

    @Test fun theStatusIsReadLeniently() {
        val s = status("""
        {"power":{"source":"battery","battery":7,"charging":false,"minutes":95,"lid":"closed","thermal":"serious"},
         "awake":{"setting":"lidClosed","holding":true,"lidClosedMode":true,"blocker":"lowBattery","helper":"enabled","otherService":false},
         "workspace":{"state":"running","setupComplete":true},
         "session":{"enabled":true,"state":"needsLogin","since":"2026-11-07T10:00:00Z"},
         "newChats":{"enabled":false},"kept":{"enabled":true,"running":3},
         "bitwarden":{"state":"unlocked","until":"2026-11-07T18:00:00Z"},"somethingNew":{"x":1}}
        """)
        assertEquals(7, s.power?.battery)
        assertEquals("closed", s.power?.lid)
        assertEquals(MacStayAwake.LID_CLOSED, s.awake?.setting)
        assertEquals(true, s.awake?.lidClosedMode)
        assertEquals("lowBattery", s.awake?.blocker)
        assertEquals("running", s.workspace?.state)
        assertEquals("needsLogin", s.session?.state)
        assertEquals(false, s.newChats?.enabled)
        assertEquals(3, s.kept)
        assertEquals("unlocked", s.bitwarden?.state)
        assertNotNull(s.bitwarden?.until)
        // An older Mac: nothing breaks
        assertEquals(MacStatus(), MacStatus.from(JsonObject(emptyMap())))
        // Wrong types count as missing
        assertNull(status("""{"power":{"battery":"76"}}""").power?.battery)
    }

    @Test fun theDisplayAndWhatToOffer() {
        val all = MacAction.entries.map { it.raw }.toSet()
        val on = status("""{"display":{"state":"on","external":1}}""")
        assertEquals(MacStatus.Display("on", 1), on.display)
        assertEquals(MacOffer(sleep = true, displayOff = true), MacOffer.now(on, all, false))
        val off = status("""{"display":{"state":"off","external":0}}""")
        assertEquals(MacOffer(sleep = true, displayOn = true), MacOffer.now(off, all, false))
        assertEquals(MacOffer(sleep = true), MacOffer.now(off, setOf("mac.status", "mac.sleep"), false))
        val none = status("""{"display":{"state":"none","external":0}}""")
        assertEquals(MacOffer(sleep = true), MacOffer.now(none, all, false))
        assertEquals(MacOffer(), MacOffer.now(on, all, true))
        assertEquals(MacOffer(sleep = true, displayOff = true), MacOffer.now(MacStatus(), emptySet(), false))
    }

    @Test fun refusalsAreWordedHere() {
        assertTrue(MacRefusal("sleep-disabled", "x").text.contains("pmset disablesleep"))
        assertEquals("As the Mac says", MacRefusal("unheard-of", "As the Mac says").text)
        assertEquals("aOS on the Mac said no.", MacRefusal(null, "").text)
    }

    @Test fun actionResults() {
        val r = CompanionResponse(1, true, null, obj("""{"id":1,"ok":true,"sleeping":true,"after":1.5,"status":{"display":{"state":"on"}},"signOut":"done"}"""))
        val result = MacActionResult.from(r)
        assertEquals(1.5, result.sleepsIn)
        assertEquals("on", result.status?.display?.state)
        assertEquals("done", result.signOut)
        assertNull(MacActionResult.from(CompanionResponse(2, true, null, obj("""{"id":2,"ok":true}"""))).sleepsIn)
    }
}

class WorkspaceOperationTests {
    private fun run(op: WorkspaceOperation, vararg states: String): List<WorkspaceOperation.Outcome> {
        var current = op
        return states.map { state -> current.observe(state).also { current = it.second }.first }
    }

    @Test fun aCloseIsDoneWhenTheWorkspaceIsClosedNotWhenTheMacAnswers() {
        val close = WorkspaceOperation(WorkspaceOperation.Kind.STOP, "open")
        assertEquals(listOf(WorkspaceOperation.Outcome.UNDER_WAY, WorkspaceOperation.Outcome.UNDER_WAY,
            WorkspaceOperation.Outcome.UNDER_WAY, WorkspaceOperation.Outcome.DONE), run(close, "open", "running", "closing", "stopped"))
        assertEquals("closing", close.shownState)
    }

    @Test fun aStartIsDoneWhenItRunsAndFailsOnlyWithANewFailure() {
        val start = WorkspaceOperation(WorkspaceOperation.Kind.START, "stopped")
        assertEquals(WorkspaceOperation.Outcome.DONE, run(start, "stopped", "starting", "running").last())
        assertEquals(WorkspaceOperation.Outcome.DONE, run(start, "open").last())
        val again = WorkspaceOperation(WorkspaceOperation.Kind.START, "failed")
        assertEquals(listOf(WorkspaceOperation.Outcome.UNDER_WAY, WorkspaceOperation.Outcome.UNDER_WAY, WorkspaceOperation.Outcome.FAILED),
            run(again, "failed", "starting", "failed"))
        assertEquals(WorkspaceOperation.Outcome.FAILED, run(WorkspaceOperation(WorkspaceOperation.Kind.START, "stopped"), "failed").last())
        assertEquals("starting", start.shownState)
    }

    @Test fun itTakesMinutesAtMost() {
        val then = Instant.ofEpochSecond(1_000_000)
        val start = WorkspaceOperation(WorkspaceOperation.Kind.START, "stopped", then)
        assertEquals(WorkspaceOperation.Outcome.UNDER_WAY, start.observe("starting", then.plusSeconds(4 * 60 + 59)).first)
        assertEquals(WorkspaceOperation.Outcome.TIMED_OUT, start.observe("starting", then.plusSeconds(5 * 60)).first)
        val close = WorkspaceOperation(WorkspaceOperation.Kind.STOP, "running", then)
        assertEquals(WorkspaceOperation.Outcome.TIMED_OUT, close.observe("running", then.plusSeconds(3 * 60)).first)
        assertTrue(close.timeoutText.contains("3") && start.timeoutText.contains("5"))
        assertTrue(close.arrived("stopped"))
    }

    @Test fun onlyStartAndCloseAreOperations() {
        assertEquals(WorkspaceOperation.Kind.START, WorkspaceOperation.of(MacAction.WORKSPACE_START, null)?.kind)
        assertEquals(WorkspaceOperation.Kind.STOP, WorkspaceOperation.of(MacAction.WORKSPACE_STOP, null)?.kind)
        assertNull(WorkspaceOperation.of(MacAction.DISPLAY_OFF, null))
    }
}

class ChatsTests {
    private val id = "6f1d6a0e-2b7c-4d8a-9c3e-1a2b3c4d5e01"
    private fun chat(id: String, pinned: Boolean = false, skipped: Boolean = false, state: String? = null,
                     note: String? = null, reason: String? = null) =
        ChatList.Chat(id, id, pinned = pinned, skipped = skipped, state = state, note = note, reason = reason)

    @Test fun theListIsReadLeniently() {
        val chats = ChatList.from(obj("""
        {"enabled":true,"automatic":true,"terminal":false,"hours":48,"max":6,"running":1,"restart":true,"somethingNew":1,
         "list":[{"id":"a","title":"Rechnungen","folder":"~/Documents/Finanzen","origin":"app","activity":"2026-11-09T10:00:00Z",
                  "pinned":true,"skipped":false,"state":"running","since":"2026-11-09T09:00:00Z"},
                 {"id":"b","title":"Website","folder":"~/Developer/site","origin":"terminal","pinned":false,"skipped":true,
                  "reason":"skipped"},
                 {"title":"no id"}, {"id":"c"}]}
        """))
        assertTrue(chats.enabled && chats.canRestart)
        assertEquals(1, chats.running)
        assertEquals(listOf("a", "b", "c"), chats.chats.map { it.id })
        assertTrue(chats.chats[0].isRunning && chats.chats[0].isReachable)
        assertNotNull(chats.chats[0].activity)
        assertEquals("Finanzen", chats.chats[0].folderName)
        assertTrue(chats.chats[1].skipped && chats.chats[1].reason == "skipped")
        assertEquals("Claude Code", chats.chats[2].title)
        assertEquals(1, chats.reachable)
        assertTrue(ChatList.from(JsonObject(emptyMap())).chats.isEmpty())
        assertFalse(ChatList.from(JsonObject(emptyMap())).enabled)
        assertEquals("~", ChatList.Chat("x", "x", folder = "~").folderName)
    }

    @Test fun reachableKeptAndIdle() {
        for (state in listOf("running", "starting", "openElsewhere")) assertTrue(chat("x", state = state).isReachable, state)
        for (state in listOf("waitingForNetwork", "needsAttention", "failed", "folderMissing")) assertFalse(chat("x", state = state).isReachable, state)
        assertTrue(chat("x").isKept)
        assertTrue(chat("x", pinned = true, reason = "overLimit").isKept)
        assertFalse(chat("x", reason = "inactive").isKept)
        assertFalse(chat("x", skipped = true, reason = "skipped").isKept)
        assertTrue(chat("x", reason = "inactive").isIdle)
        assertTrue(chat("x", state = "failed").isIdle)
        assertFalse(chat("x", state = "needsAttention").isIdle)
        assertFalse(chat("x", state = "hibernating").isIdle)
    }

    @Test fun whatTheOpsSign() {
        for (action in listOf(MacAction.CHATS_START, MacAction.CHATS_STOP, MacAction.CHATS_DELETE, MacAction.CHATS_PIN)) {
            val fields = CompanionRequest.Mac(action, id).signatureFields("k", 1, "n")
            assertEquals("companion." + action.raw, fields.op)
            assertEquals(CompanionSignature.dataDigest(text = id), fields.data)
            assertTrue(action.changesChat)
        }
        assertTrue(MacAction.CHATS_SKIP.changesChat && !MacAction.CHATS_LIST.changesChat && !MacAction.SLEEP.changesChat)
    }

    @Test fun whatIsOffered() {
        val all = MacAction.entries.map { it.raw }.toSet()
        fun offer(c: ChatList.Chat, list: ChatList = ChatList(canRestart = true), features: Set<String> = all) = ChatOffer.now(c, list, features)
        val running = chat("a", pinned = true, state = "running")
        assertEquals(ChatOffer(stop = MacAction.CHATS_STOP, restart = true), offer(running))
        assertEquals(ChatOffer(stop = MacAction.CHATS_STOP), offer(chat("e", state = "openElsewhere", note = "app")))
        val older = chat("b", reason = "inactive")
        assertEquals(ChatOffer(start = MacAction.CHATS_START, delete = true), offer(older))
        val stopped = chat("c", skipped = true, reason = "skipped")
        assertEquals(ChatOffer(start = MacAction.CHATS_START, delete = true), offer(stopped))
        val soon = chat("f")
        assertEquals(ChatOffer(start = MacAction.CHATS_START, stop = MacAction.CHATS_STOP, delete = true), offer(soon))
        val failed = chat("g", pinned = true, state = "failed")
        assertEquals(ChatOffer(stop = MacAction.CHATS_STOP, restart = true, delete = true), offer(failed))
        assertEquals(ChatOffer(stop = MacAction.CHATS_STOP, restart = true), offer(chat("h", state = "needsAttention", note = "signIn")))
        assertEquals(ChatOffer(stop = MacAction.CHATS_STOP, delete = true), offer(chat("m", state = "folderMissing")))
        assertEquals(ChatOffer(delete = true), offer(chat("d", reason = "archived")))
        assertTrue(offer(chat("o", reason = "ownSession")).isEmpty)
        assertFalse(offer(chat("x", state = "hibernating")).delete)
        assertNull(offer(older, ChatList(enabled = false)).start)
        assertFalse(offer(running, ChatList(canRestart = false)).restart)
        assertEquals(MacAction.CHATS_START, offer(failed, ChatList(canRestart = false)).start)
        assertFalse(offer(running, features = all - "chats.restart").restart)
        val olderMac = all - setOf("chats.start", "chats.stop", "chats.delete")
        assertEquals(ChatOffer(start = MacAction.CHATS_PIN), offer(stopped, features = olderMac))
        assertEquals(ChatOffer(stop = MacAction.CHATS_SKIP, restart = true), offer(running, features = olderMac))
        assertEquals(ChatOffer(start = MacAction.CHATS_PIN, stop = MacAction.CHATS_SKIP), offer(soon, features = olderMac))
        assertTrue(offer(soon, features = setOf("chats.list")).isEmpty)
    }
}

class AppsAndRoutinesTests {
    @Test fun absentWhileTheFeatureIsOff() {
        assertNull(MacStatus.from(JsonObject(emptyMap())).apps)
        assertNull(status("""{"session":{"enabled":true,"state":"running"}}""").apps)
    }

    @Test fun connectedWithItsNetwork() {
        val apps = status("""{"apps":{"state":"connected","since":"2026-11-11T08:15:00Z","network":"cellular","device":"iPhone von Max","previousSeconds":4210,"jobs":[]}}""").apps!!
        assertTrue(apps.isConnected)
        assertEquals(Iso8601.parse("2026-11-11T08:15:00Z"), apps.since)
        assertEquals("cellular", apps.network)
        assertEquals(4210, apps.previousSeconds)
        val wifi = status("""{"apps":{"state":"connected","since":"2026-11-11T08:15:00.250Z","network":"wifi","previousSeconds":12.6}}""").apps!!
        assertNotNull(wifi.since)
        assertEquals(13, wifi.previousSeconds)
    }

    @Test fun jobsWithAndWithoutTheirOptionalFields() {
        val apps = status("""
        {"apps":{"state":"searching","jobs":[
            {"id":"1","name":"Tunnel Test","bundleId":"dev.marquart.tunneltest","state":"queued","created":"2026-11-11T09:00:00Z"},
            {"id":"2","name":"Tunnel Test","bundleId":"dev.marquart.tunneltest","state":"done","created":"2026-11-11T08:00:00Z",
             "version":"1.0 (2)","source":"Claude Code","finished":"2026-11-11T08:00:03Z","seconds":3.0,"network":"cellular"},
            {"id":"3","name":"Haushaltsbuch","bundleId":"dev.marquart.haushalt","state":"failed","created":"2026-11-10T08:00:00Z",
             "finished":"2026-11-10T08:00:08Z","seconds":8.4,"network":"wifi","message":"No profile covers it."},
            {"name":"no id","bundleId":"x","state":"done"},
            {"id":"5","bundleId":"dev.marquart.nameless"}]}}
        """).apps!!
        assertEquals(listOf("1", "2", "3", "5"), apps.jobs.map { it.id })
        assertTrue(apps.jobs[0].isPending)
        assertEquals(3.0, apps.jobs[1].seconds)
        assertEquals("No profile covers it.", apps.jobs[2].message)
        assertEquals("dev.marquart.nameless", apps.jobs[3].name)
        assertEquals("unknown", apps.jobs[3].state)
        assertEquals(1, apps.queued)
        assertEquals(0, apps.installing)
        val bare = status("""{"apps":{"jobs":"none"}}""").apps!!
        assertTrue(bare.state == "unknown" && bare.jobs.isEmpty())
    }

    @Test fun theStatusCarriesTheRoutines() {
        val routines = status("""
        {"routines":{"items":[
            {"id":"A","name":"Morgen-Briefing","schedule":"0 6 * * *","prompt":"Briefing","enabled":true,"next":"2026-11-10T05:00:00Z"},
            {"id":"B","name":"Wochenplanung","schedule":"30 17 * * 0","prompt":"Planung","enabled":false},
            {"name":"ohne id"}],
          "reminders":[{"name":"Zahnarzt","at":"2026-11-10T07:05:00Z"}],"queued":1,
          "recent":[{"kind":"routine","name":"Routine-Check","at":"2026-11-09T13:13:00Z"}]}}
        """).routines!!
        assertEquals(listOf("A", "B"), routines.items.map { it.id })
        assertFalse(routines.items[1].enabled)
        assertEquals("A", routines.next?.id)
        assertEquals("Zahnarzt", routines.reminders.first().name)
        assertEquals(1, routines.queued)
        assertEquals("routine", routines.recent.first().kind)
        assertNull(MacStatus.from(JsonObject(emptyMap())).routines)
    }

    @Test fun aRoutineGoesToTheMacWithoutItsNextTime() {
        val item = MacStatus.Routines.Item("A", "Check", "3 10 * * *", "Mach", true, Instant.now())
        assertEquals(setOf("id", "name", "schedule", "prompt", "enabled"), Json.parseObject(item.json.toByteArray())!!.keys)
    }
}
