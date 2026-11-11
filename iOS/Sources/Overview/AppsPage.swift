import SwiftUI

/// Apps that agents put on this iPhone through aOS on the Mac (AOSKit `CompanionControl.apps`): the Mac's connection to
/// the iPhone (it comes up whenever the iPhone is on any Wi-Fi and then also holds on cellular) and the latest installs.
/// Read only. Pushed from the Overview's aOS card while the feature is on on the Mac.
struct AppsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    private var connection: MacConnection? { model.connection }
    private var apps: MacStatus.Apps? { connection?.macStatus?.apps }

    var body: some View {
        List {
            if let apps {
                Section {
                    OverviewRow(symbol: AppsText.connectionSymbol(apps), tint: AppsText.connectionTint(apps),
                                title: AppsText.connectionTitle(apps), detail: AppsText.connectionExplanation(apps))
                    if let device = apps.device, !device.isEmpty {
                        LabeledContent("iPhone", value: device)
                    }
                    if apps.isConnected, let since = apps.since {
                        LabeledContent("Connected since", value: AppsText.since(since))
                    }
                    if apps.isConnected, let network = apps.network {
                        LabeledContent("Network", value: AppsText.networkName(network))
                    }
                    if let previous = apps.previousSeconds {
                        LabeledContent("Previous connection held", value: AppsText.duration(previous))
                    }
                }
                Section {
                    if apps.jobs.isEmpty {
                        Text("Nothing installed yet.").foregroundStyle(.secondary)
                    }
                    ForEach(apps.jobs) { job in
                        AppJobRow(job: job)
                    }
                } header: {
                    Text("Installs")
                } footer: {
                    Text("Your agents put apps on this iPhone through aOS. When there is no connection, installs wait until the iPhone is on any Wi-Fi.")
                }
            } else {
                ContentUnavailableView("Off on the Mac", systemImage: "apps.iphone",
                                       description: Text("Switch on “Install apps on my iPhone” in aOS on the Mac (Settings > Apps)."))
            }
        }
        .navigationTitle("Apps")
        .animation(.snappy, value: apps?.jobs)
        .refreshable { await connection?.refreshMacStatus() }
        // The status now and while the page is on screen: every 5 s while an install waits or runs, else every 15 s.
        .task(id: [connection?.companionState == .ready, scenePhase == .active]) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await connection?.refreshMacStatus()
                let pending = (apps?.queued ?? 0) + (apps?.installing ?? 0) > 0
                try? await Task.sleep(for: .seconds(pending ? 5 : 15))
            }
        }
    }
}

/// One install: the app and its version with the time, its state and who asked, the bundle id and how it went.
struct AppJobRow: View {
    let job: MacStatus.Apps.Job

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: AppsText.symbol(job))
                .font(.body.weight(.medium))
                .foregroundStyle(AppsText.tint(job))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(job.name).font(.body.weight(.semibold)).lineLimit(2)
                    if let version = job.version, !version.isEmpty {
                        Text(version).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                    Spacer(minLength: 8)
                    if let at = job.finished ?? job.created {
                        Text(AppsText.timeShort(at)).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                    }
                }
                Text(AppsText.stateLine(job)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                Text(AppsText.detail(job)).font(.footnote).foregroundStyle(.tertiary).lineLimit(2)
                if job.state == "failed", let message = job.message, !message.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Installing apps on this iPhone in words (and symbols and colors), kept apart from the views for the tests.
enum AppsText {
    /// The Overview's Apps row: the connection, and the installs not done yet. One line each.
    static func overview(_ apps: MacStatus.Apps) -> String {
        [connectionShort(apps), pendingShort(apps)].compactMap { $0 }.joined(separator: "\n")
    }

    /// The Mac's connection to this iPhone in a few words (the Overview's row).
    static func connectionShort(_ apps: MacStatus.Apps) -> String {
        guard apps.isConnected else { return connectionTitle(apps) }
        switch apps.network {
        case "wifi": return String(localized: "Connected, on Wi-Fi")
        case "cellular": return String(localized: "Connected, on cellular")
        default: return String(localized: "Connected")
        }
    }

    /// The connection's state (the page's first row; the network has a row of its own there).
    static func connectionTitle(_ apps: MacStatus.Apps) -> String {
        switch apps.state {
        case "connected": String(localized: "Connected")
        case "searching", "connecting", "starting": String(localized: "Waiting for Wi-Fi")
        case "notPaired": String(localized: "Not paired")
        case "stopped": String(localized: "Off")
        default: String(localized: "State unknown")
        }
    }

    /// What the state means, where it helps.
    static func connectionExplanation(_ apps: MacStatus.Apps) -> String? {
        switch apps.state {
        case "connected":
            apps.network == "cellular"
                ? String(localized: "The connection holds on cellular too, until the iPhone restarts.") : nil
        case "searching", "connecting", "starting":
            String(localized: "aOS on the Mac connects as soon as this iPhone is on any Wi-Fi.")
        case "notPaired":
            String(localized: "Connect this iPhone to the Mac with a cable once, then pair it in aOS on the Mac (Settings > Apps).")
        case "stopped":
            String(localized: "aOS on the Mac doesn't keep the connection right now. Look in aOS on the Mac (Settings > Apps).")
        default: nil
        }
    }

    static func connectionSymbol(_ apps: MacStatus.Apps) -> String {
        switch apps.state {
        case "connected": apps.network == "cellular" ? "antenna.radiowaves.left.and.right" : "wifi"
        case "searching", "connecting", "starting": "hourglass"
        case "notPaired": "cable.connector"
        case "stopped": "pause.circle"
        default: "questionmark.circle"
        }
    }

    static func connectionTint(_ apps: MacStatus.Apps) -> Color {
        switch apps.state {
        case "connected": .green
        case "notPaired": .orange
        default: .secondary
        }
    }

    /// Installs not done yet, in a line of the Overview's row (nil when there are none).
    static func pendingShort(_ apps: MacStatus.Apps) -> String? {
        let count = apps.queued + apps.installing
        if apps.installing > 0 {
            return count == 1 ? String(localized: "1 app is being installed")
                              : String(localized: "\(count) apps are being installed")
        }
        switch count {
        case 0: return nil
        case 1: return String(localized: "1 app waits")
        default: return String(localized: "\(count) apps wait")
        }
    }

    static func networkName(_ network: String) -> String {
        switch network {
        case "wifi": String(localized: "Wi-Fi")
        case "cellular": String(localized: "Cellular")
        default: network
        }
    }

    /// The time today, else the weekday with it.
    static func since(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
                                             : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "1 hr, 10 min", "4 min, 30 sec" (the two largest units, in the app's language).
    static func duration(_ seconds: Int) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.days, .hours, .minutes] : [.minutes, .seconds]
        return Duration.seconds(max(0, seconds)).formatted(.units(allowed: units, width: .abbreviated, maximumUnitCount: 2))
    }

    /// "4 min. ago", "yesterday" (as short as it gets).
    static func timeShort(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    static func symbol(_ job: MacStatus.Apps.Job) -> String {
        switch job.state {
        case "done": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "queued", "installing": "clock"
        default: "questionmark.circle"
        }
    }

    static func tint(_ job: MacStatus.Apps.Job) -> Color {
        switch job.state {
        case "done": .green
        case "failed": .red
        case "installing": BrandColor.indigo
        default: .secondary
        }
    }

    static func state(_ job: MacStatus.Apps.Job) -> String {
        switch job.state {
        case "done": String(localized: "Installed")
        case "failed": String(localized: "Failed")
        case "installing": String(localized: "Installing")
        case "queued": String(localized: "Waiting")
        default: job.state
        }
    }

    /// The state and who asked: "Installed · Claude Code".
    static func stateLine(_ job: MacStatus.Apps.Job) -> String {
        [state(job), job.source].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The bundle id, how long it took, "on cellular" when it went over cellular.
    static func detail(_ job: MacStatus.Apps.Job) -> String {
        var parts = [job.bundleId].filter { !$0.isEmpty }
        if let seconds = job.seconds, seconds >= 0, seconds < 1e6 {
            parts.append(String(localized: "\(max(1, Int(seconds.rounded()))) s"))
        }
        if job.network == "cellular" { parts.append(String(localized: "on cellular")) }
        return parts.joined(separator: " · ")
    }
}
