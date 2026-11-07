import AOSKit
import ServiceManagement
import SwiftUI

/// Settings > General: keeping the Mac awake (also with the lid closed) and the iPhone hotspot question.
struct StayAwakeSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var power: PowerController

    var body: some View {
        Section {
            Picker("Keep this Mac awake", selection: Binding(get: { model.settings.stayAwake },
                                                              set: { v in model.update { $0.stayAwake = v } })) {
                Text("Off").tag(StayAwake.off)
                Text("While the lid is open").tag(StayAwake.lidOpen)
                Text("Also with the lid closed").tag(StayAwake.lidClosed)
            }
            .disabled(power.cloupiPresent)
            if power.cloupiPresent {
                OtherWakeServiceNote()
            } else {
                Text(explanation).font(.caption).foregroundStyle(.secondary)
                if model.settings.stayAwake == .lidClosed {
                    Picker("On battery, stay awake down to", selection: Binding(
                        get: { model.settings.stayAwakeMinBattery },
                        set: { v in model.update { $0.stayAwakeMinBattery = v } })) {
                        ForEach(AgentSettings.stayAwakeMinBatteryChoices, id: \.self) { p in
                            if p == 0 { Text("No limit").tag(p) } else { Text(verbatim: "\(p) %").tag(p) }
                        }
                        if !AgentSettings.stayAwakeMinBatteryChoices.contains(model.settings.stayAwakeMinBattery) {
                            Text(verbatim: "\(model.settings.stayAwakeMinBattery) %").tag(model.settings.stayAwakeMinBattery)
                        }
                    }
                    HelperRow()
                    if let state = stateText {
                        Label(state.text, systemImage: state.symbol)
                            .font(.caption).foregroundStyle(state.warning ? .orange : .secondary)
                    }
                }
            }
        } header: {
            Text("Staying awake")
        }
    }

    var explanation: String {
        switch model.settings.stayAwake {
        case .off:
            return String(localized: "The Mac sleeps as usual. Sessions, kept conversations and the workspace pause while it sleeps.")
        case .lidOpen:
            return String(localized: "While a session, a kept conversation or the workspace runs, the Mac doesn't go to sleep by itself. Closing the lid puts it to sleep.")
        case .lidClosed:
            return String(localized: "The Mac also stays awake with the lid closed, on battery too. Meanwhile \(Brand.name) freezes your other apps and turns the display off; when you open the lid, everything continues. Claude, terminals, code editors and your agents keep running. On battery it stays awake down to the level you choose below; then, or when it gets too hot, the Mac sleeps.")
        }
    }

    var stateText: (text: String, symbol: String, warning: Bool)? {
        switch power.decision.blocker {
        case .lowBattery?:
            let level = max(model.settings.stayAwakeMinBattery, HoldPolicy.floorPercent)
            return (String(localized: "Battery below \(level) percent: the Mac may sleep now."), "battery.25", true)
        case .thermal?: return (String(localized: "The Mac is too hot: it may sleep now."), "thermometer.high", true)
        case .nothingToKeep?: return (String(localized: "Nothing to keep reachable right now: the Mac sleeps as usual."), "moon", false)
        default: break
        }
        if power.decision.lidClosedMode {
            let n = power.frozenApps.count
            let text = n == 0 ? String(localized: "Lid closed: the Mac stays awake.")
                : (n == 1 ? String(localized: "Lid closed: 1 app frozen until you open it.")
                   : String(localized: "Lid closed: \(n) apps frozen until you open it."))
            return (text, "laptopcomputer", false)
        }
        if power.holding { return (String(localized: "Ready: the Mac stays awake when you close the lid."), "checkmark.circle", false) }
        return nil
    }
}

/// The background helper's state, with the one action macOS may need from the user.
struct HelperRow: View {
    @EnvironmentObject var power: PowerController

    var body: some View {
        LabeledContent {
            if power.helperStatus == .enabled {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if power.helperApproving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your yes").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Allow …") { power.startHelperApproval() }.buttonStyle(.glass)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Background helper")
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if power.helperApproving { HelperApprovalSteps().padding(.top, 4) }
                if let note = power.helperNote {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .onAppear { power.refreshHelperStatus() }
    }

    var detail: String {
        switch power.helperStatus {
        case .enabled:
            return String(localized: "Keeps the workspace's keys and disk and runs Bitwarden apart from your other programs. Also keeps the Mac awake with the lid closed and looks after Wi-Fi.")
        default:
            return String(localized: "Needed for the workspace, for Bitwarden and to keep the Mac awake with the lid closed. macOS asks you once to allow it.")
        }
    }
}

/// What macOS shows while the person allows the helper, so nothing looks stuck.
struct HelperApprovalSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            step(1, "macOS briefly shows the notice \"Background items added\".")
            step(2, "System Settings opens at Login Items & Extensions: under \"Allow in the Background\", switch on aOS.")
            step(3, "macOS asks for your password or Touch ID.")
            step(4, "Then a check mark appears here. Nothing else to do.")
        }
        .font(.caption)
    }

    func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n)").fontWeight(.bold).foregroundStyle(BrandColor.indigo).frame(width: 12)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The guided way to allow the helper, as a card for the setup: why, what comes, waiting, done.
struct HelperApprovalCard: View {
    @EnvironmentObject var power: PowerController
    let reason: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if power.helperStatus == .enabled {
                Label("aOS's background helper is allowed.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout.weight(.medium))
            } else {
                Text(reason).font(.callout)
                HelperApprovalSteps()
                HStack(spacing: 10) {
                    if power.helperApproving {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your yes in System Settings …").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Again") { power.openLoginItems() }.buttonStyle(.glass)
                    } else {
                        Spacer()
                        Button("Allow the Background Helper …") { power.startHelperApproval() }.buttonStyle(.glassProminent)
                    }
                }
            }
        }
        .onAppear { power.refreshHelperStatus() }
    }
}

/// Another wake service on this Mac already keeps it awake and looks after Wi-Fi: two would fight over both.
struct OtherWakeServiceNote: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Another service takes care of this")
                Text("Another service on this Mac already keeps it awake and looks after Wi-Fi. \(Brand.name) leaves both alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "checkmark.seal").foregroundStyle(BrandColor.indigo)
        }
    }
}

/// The iPhone's hotspot: where the person sets how macOS joins it (aOS can't change it).
struct HotspotSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var power: PowerController

    var body: some View {
        Section {
            if power.cloupiPresent {
                OtherWakeServiceNote()
            } else {
                HotspotHint()
                if let w = power.wifi { HotspotStateLine(state: w, choice: nil) }
            }
        } header: {
            Text("iPhone hotspot")
        }
        .onAppear { power.refreshWiFiState() }
    }
}

/// How the Mac reaches the internet through the iPhone's hotspot with the lid closed. macOS doesn't let apps change
/// this (not even aOS's helper as root, macOS 27), so aOS only says where the person sets it.
struct HotspotHint: View {
    @EnvironmentObject var power: PowerController
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your iPhone's hotspot with the lid closed")
                .fontWeight(compact ? .medium : .regular)
            Text("If the Mac should go online through your iPhone when there's no Wi-Fi, set it up once in macOS (\(Brand.name) can't, macOS doesn't let apps change Wi-Fi settings):")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                hintStep("1", "Join your iPhone's hotspot once from the Wi-Fi menu.")
                hintStep("2", "In Wi-Fi settings, click (i) next to it and switch on Auto-Join.")
                hintStep("3", "Under \"Ask to join hotspots\" choose Automatic (the Mac joins by itself) or Ask to Join (it asks first).")
            }
            Button("Open Wi-Fi Settings") { power.openWiFiSettings() }.buttonStyle(.glass)
        }
    }

    func hintStep(_ number: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number).font(.caption.weight(.bold)).foregroundStyle(BrandColor.indigo).frame(width: 14)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What macOS does now, read back from it.
struct HotspotStateLine: View {
    let state: WiFiState
    let choice: HotspotJoin?

    var body: some View {
        HStack(spacing: 6) {
            if let choice {
                StatusDot(color: state.matches(choice) ? .green : .orange)
            }
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    var text: String {
        // macOS's own names for "Ask to join hotspots", so the user finds them again in the Wi-Fi settings.
        let mode: String
        switch state.hotspotMode {
        case .automatic?: mode = String(localized: "Automatic")
        case .askToJoin?: mode = String(localized: "Ask to Join")
        case .never?: mode = String(localized: "Never")
        case nil: mode = String(localized: "unknown")
        }
        guard let total = state.personalHotspots, total > 0 else {
            return String(localized: "No iPhone hotspot known to this Mac yet: join yours once from the Wi-Fi menu. Ask to join hotspots: \(mode).")
        }
        let off = state.autoJoinOff ?? 0
        let autoJoin = off == 0 ? String(localized: "on") : (off == total ? String(localized: "off") : String(localized: "mixed"))
        return String(localized: "Now in macOS: auto-join for your hotspot \(autoJoin), Ask to join hotspots: \(mode).")
    }
}
