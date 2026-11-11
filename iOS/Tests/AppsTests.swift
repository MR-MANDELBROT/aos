import Foundation
import Testing
@testable import aOS

/// Installing apps on this iPhone as the Mac reports it in `mac.status` (`apps`): read leniently, and in words for the
/// Overview's row and the Apps page.
struct AppsTests {
    typealias Apps = MacStatus.Apps
    typealias Job = MacStatus.Apps.Job

    func status(_ json: String) throws -> MacStatus {
        MacStatus(try #require(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).object))
    }

    @Test func absentWhileTheFeatureIsOff() throws {
        #expect(MacStatus([:]).apps == nil)
        #expect(try status(#"{"session":{"enabled":true,"state":"running"}}"#).apps == nil)
    }

    @Test func connectedWithItsNetwork() throws {
        let apps = try #require(try status("""
        {"apps":{"state":"connected","since":"2026-11-11T08:15:00Z","network":"cellular","device":"iPhone von Max",
                 "previousSeconds":4210,"jobs":[]}}
        """).apps)
        #expect(apps.state == "connected" && apps.isConnected)
        #expect(apps.since == ISO8601.parse("2026-11-11T08:15:00Z"))
        #expect(apps.network == "cellular")
        #expect(apps.device == "iPhone von Max")
        #expect(apps.previousSeconds == 4210)
        #expect(apps.jobs.isEmpty)
        #expect(AppsText.overview(apps) == String(localized: "Connected, on cellular"))
        #expect(AppsText.connectionSymbol(apps) == "antenna.radiowaves.left.and.right")
        // Fractional seconds in the date, a non-integer duration: still read
        let wifi = try #require(try status("""
        {"apps":{"state":"connected","since":"2026-11-11T08:15:00.250Z","network":"wifi","previousSeconds":12.6}}
        """).apps)
        #expect(wifi.since != nil)
        #expect(wifi.previousSeconds == 13)
        #expect(wifi.device == nil && wifi.jobs.isEmpty)
        #expect(AppsText.overview(wifi) == String(localized: "Connected, on Wi-Fi"))
        #expect(AppsText.connectionSymbol(wifi) == "wifi")
    }

    @Test func jobsWithAndWithoutTheirOptionalFields() throws {
        let apps = try #require(try status("""
        {"apps":{"state":"searching","jobs":[
            {"id":"1","name":"Tunnel Test","bundleId":"dev.marquart.tunneltest","state":"queued","created":"2026-11-11T09:00:00Z"},
            {"id":"2","name":"Tunnel Test","bundleId":"dev.marquart.tunneltest","state":"done","created":"2026-11-11T08:00:00Z",
             "version":"1.0 (2)","source":"Claude Code","finished":"2026-11-11T08:00:03Z","seconds":3.0,"network":"cellular"},
            {"id":"3","name":"Haushaltsbuch","bundleId":"dev.marquart.haushalt","state":"failed","created":"2026-11-10T08:00:00Z",
             "finished":"2026-11-10T08:00:08Z","seconds":8.4,"network":"wifi","message":"No profile covers it."},
            {"name":"no id","bundleId":"x","state":"done"},
            {"id":"5","bundleId":"dev.marquart.nameless"}]}}
        """).apps)
        #expect(apps.state == "searching" && !apps.isConnected)
        #expect(apps.since == nil && apps.network == nil)
        #expect(apps.jobs.map(\.id) == ["1", "2", "3", "5"], "one without an id is left out, the order is the Mac's")

        let queued = apps.jobs[0]
        #expect(queued.state == "queued" && queued.isPending)
        #expect(queued.created == ISO8601.parse("2026-11-11T09:00:00Z"))
        #expect(queued.version == nil && queued.source == nil && queued.finished == nil)
        #expect(queued.seconds == nil && queued.network == nil && queued.message == nil)

        let done = apps.jobs[1]
        #expect(!done.isPending)
        #expect(done.version == "1.0 (2)" && done.source == "Claude Code")
        #expect(done.finished == ISO8601.parse("2026-11-11T08:00:03Z"))
        #expect(done.seconds == 3 && done.network == "cellular")
        #expect(AppsText.symbol(done) == "checkmark.circle.fill")
        #expect(AppsText.stateLine(done) == String(localized: "Installed") + " · Claude Code")
        #expect(AppsText.detail(done) == "dev.marquart.tunneltest · " + String(localized: "\(3) s") + " · "
                    + String(localized: "on cellular"))

        let failed = apps.jobs[2]
        #expect(failed.state == "failed" && failed.message == "No profile covers it.")
        #expect(AppsText.symbol(failed) == "xmark.octagon.fill")
        #expect(AppsText.detail(failed) == "dev.marquart.haushalt · " + String(localized: "\(8) s"), "Wi-Fi isn't mentioned")

        // Only an id: the bundle id stands in for the name, the state is unknown
        let bare = apps.jobs[3]
        #expect(bare.name == "dev.marquart.nameless" && bare.state == "unknown" && bare.created == nil)
        #expect(!bare.isPending)

        // The row: waiting for Wi-Fi, and the one waiting install
        #expect(apps.queued == 1 && apps.installing == 0)
        #expect(AppsText.overview(apps) == String(localized: "Waiting for Wi-Fi") + "\n" + String(localized: "1 app waits"))
    }

    @Test func unknownStatesDontBreakIt() throws {
        let apps = try #require(try status("""
        {"apps":{"state":"hovering","network":"satellite","jobs":[
            {"id":"1","name":"A","bundleId":"a","state":"teleporting","created":"not a date"}]}}
        """).apps)
        #expect(apps.state == "hovering" && !apps.isConnected)
        #expect(apps.jobs.count == 1)
        #expect(apps.jobs[0].state == "teleporting" && apps.jobs[0].created == nil && !apps.jobs[0].isPending)
        #expect(AppsText.overview(apps) == String(localized: "State unknown"))
        #expect(AppsText.connectionExplanation(apps) == nil)
        #expect(AppsText.state(apps.jobs[0]) == "teleporting")
        #expect(AppsText.symbol(apps.jobs[0]) == "questionmark.circle")
        #expect(AppsText.networkName("satellite") == "satellite")
        // No state at all, jobs that aren't a list: an Apps block all the same
        let bare = try #require(try status(#"{"apps":{"jobs":"none"}}"#).apps)
        #expect(bare.state == "unknown" && bare.jobs.isEmpty)
        // The rest of the status is still read
        #expect(try status(#"{"apps":{"state":"x"},"bitwarden":{"state":"locked"}}"#).bitwarden?.state == "locked")
    }

    @Test func theRowInWords() {
        func apps(_ state: String, network: String? = nil, jobs: [String] = []) -> Apps {
            Apps(state: state, network: network,
                 jobs: jobs.enumerated().map { Job(id: "\($0.offset)", name: "A", bundleId: "a", state: $0.element) })
        }
        #expect(AppsText.overview(apps("connected")) == String(localized: "Connected"))
        for state in ["searching", "connecting", "starting"] {
            #expect(AppsText.overview(apps(state)) == String(localized: "Waiting for Wi-Fi"), "\(state)")
        }
        #expect(AppsText.overview(apps("notPaired")) == String(localized: "Not paired"))
        #expect(AppsText.overview(apps("stopped")) == String(localized: "Off"))
        // Installs not done yet on a second line; done and failed ones don't count
        #expect(AppsText.pendingShort(apps("connected", jobs: ["done", "failed"])) == nil)
        #expect(AppsText.pendingShort(apps("searching", jobs: ["queued", "queued", "done"]))
                    == String(localized: "\(2) apps wait"))
        #expect(AppsText.pendingShort(apps("connected", jobs: ["installing"])) == String(localized: "1 app is being installed"))
        #expect(AppsText.overview(apps("connected", network: "wifi", jobs: ["installing", "queued"]))
                    == String(localized: "Connected, on Wi-Fi") + "\n" + String(localized: "\(2) apps are being installed"))
    }

    @Test func thePageInWords() {
        #expect(AppsText.connectionTitle(Apps(state: "connected", network: "wifi")) == String(localized: "Connected"))
        #expect(AppsText.connectionExplanation(Apps(state: "connected", network: "wifi")) == nil)
        #expect(AppsText.connectionExplanation(Apps(state: "connected", network: "cellular")) != nil)
        #expect(AppsText.connectionExplanation(Apps(state: "searching")) != nil)
        #expect(AppsText.connectionExplanation(Apps(state: "notPaired")) != nil)
        #expect(AppsText.connectionSymbol(Apps(state: "notPaired")) == "cable.connector")
        #expect(AppsText.networkName("wifi") == String(localized: "Wi-Fi"))
        #expect(AppsText.networkName("cellular") == String(localized: "Cellular"))
        #expect(!AppsText.duration(4210).isEmpty)
        // Jobs: a symbol and a word per state
        let installing = Job(id: "1", name: "A", bundleId: "a", state: "installing", source: "Claude Code")
        #expect(AppsText.symbol(installing) == "clock")
        #expect(AppsText.stateLine(installing) == String(localized: "Installing") + " · Claude Code")
        #expect(AppsText.detail(installing) == "a")
        let queued = Job(id: "2", name: "A", bundleId: "a", state: "queued")
        #expect(AppsText.symbol(queued) == "clock")
        #expect(AppsText.stateLine(queued) == String(localized: "Waiting"))
        // Under a second still says 1 s
        #expect(AppsText.detail(Job(id: "3", name: "A", bundleId: "a", state: "done", seconds: 0.3))
                    == "a · " + String(localized: "\(1) s"))
    }

    @Test func theDemoShowsThem() throws {
        let apps = try #require(MacStatus(MockCompanionServer.demoMacStatus).apps)
        #expect(apps.isConnected && apps.network == "wifi")
        #expect(apps.jobs.count == 4 && apps.installing == 1)
    }
}
