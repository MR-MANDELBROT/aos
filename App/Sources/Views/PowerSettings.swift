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
                CloupiNote()
            } else {
                Text(explanation).font(.caption).foregroundStyle(.secondary)
                if model.settings.stayAwake == .lidClosed {
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
            return String(localized: "The Mac also stays awake with the lid closed, on battery too. Meanwhile \(Brand.name) freezes your other apps and turns the display off; when you open the lid, everything continues. Claude, terminals, code editors and your agents keep running. Below 10 percent battery, or when it gets too hot, the Mac sleeps.")
        }
    }

    var stateText: (text: String, symbol: String, warning: Bool)? {
        switch power.decision.blocker {
        case .lowBattery?: return (String(localized: "Battery below 10 percent: the Mac may sleep now."), "battery.25", true)
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
            switch power.helperStatus {
            case .enabled:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .requiresApproval:
                Button("Open Login Items") { power.openLoginItems() }.buttonStyle(.glass)
            default:
                Button("Set Up") { power.ensureHelperRegistered() }.buttonStyle(.glass)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Background helper")
                Text(detail).font(.caption).foregroundStyle(.secondary)
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
            return String(localized: "Keeps the Mac awake with the lid closed and changes Wi-Fi settings for you.")
        case .requiresApproval:
            return String(localized: "macOS asks you once: switch on \(Brand.name) under Login Items & Extensions, \"Allow in the Background\".")
        default:
            return String(localized: "Needed to keep the Mac awake with the lid closed. macOS asks you once to allow it.")
        }
    }
}

struct CloupiNote: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Managed by Cloupi")
                Text("Cloupi's own service keeps this Mac awake and looks after Wi-Fi. \(Brand.name) leaves both alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "checkmark.seal").foregroundStyle(BrandColor.indigo)
        }
    }
}

/// The hotspot question: macOS joins the iPhone's hotspot by itself, or only when the user switches it on.
struct HotspotSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var power: PowerController

    var body: some View {
        Section {
            if power.cloupiPresent {
                CloupiNote()
            } else {
                HotspotChoice()
                if let w = power.wifi { HotspotStateLine(state: w, choice: model.settings.hotspotJoin) }
                switch power.hotspotApply {
                case .idle, .done:
                    EmptyView()
                case .working:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Changing the Wi-Fi settings. Wi-Fi reconnects for a moment.").font(.caption)
                    }
                case .waitingForHelper:
                    HelperRow()
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Label("macOS didn't take the change.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("Try Again") { if let j = model.settings.hotspotJoin { power.applyHotspot(j) } }
                                .buttonStyle(.glass)
                            Button("Open Wi-Fi Settings") { power.openWiFiSettings() }.buttonStyle(.glass)
                        }
                    }
                }
            }
        } header: {
            Text("iPhone hotspot")
        }
        .onAppear { power.refreshWiFiState() }
    }
}

/// The two answers, as radio buttons with an explanation each.
struct HotspotChoice: View {
    @EnvironmentObject var model: AppModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When should this Mac join your iPhone's hotspot?")
                .fontWeight(compact ? .medium : .regular)
            option(.manual, "Only when I switch it on on the iPhone",
                   "macOS never joins or wakes your hotspot by itself. Switch it on and \(Brand.name) connects (with the lid closed as soon as your iPhone sends it); switch it off and the Mac stays disconnected. Meanwhile the Mac keeps looking for known Wi-Fi.")
            option(.automatic, "Automatically (uses more energy)",
                   "macOS joins your hotspot whenever it can and may switch it on by itself when there's no Wi-Fi. That keeps your iPhone's hotspot busy and uses its battery.")
            if model.settings.hotspotJoin == nil {
                Text("\(Brand.name) changes this in macOS's Wi-Fi settings for you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func option(_ value: HotspotJoin, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        let selected = model.settings.hotspotJoin == value
        return Button {
            model.update { $0.hotspotJoin = value }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? BrandColor.indigo : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(selected ? .semibold : .regular)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
