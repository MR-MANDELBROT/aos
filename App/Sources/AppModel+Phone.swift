import AOSKit
import ServiceManagement

/// What the iPhone's Overview reads and changes on this Mac through its signed requests (AOSKit
/// CompanionControl): staying awake and sleep live here, in the app; the workspace, Bitwarden and the Claude Code
/// session are AOSKit's own.
extension AppModel: MacControls {
    func awakeStatus() -> MacAwakeStatus {
        MacAwakeStatus(setting: settings.stayAwake, holding: power.holding,
                       lidClosedMode: power.decision.lidClosedMode && power.holding,
                       blocker: power.decision.blocker?.rawValue, helper: Self.helperName(power.helperStatus),
                       otherService: power.cloupiPresent, batteryLimit: settings.stayAwakeMinBattery,
                       batteryLimits: AgentSettings.stayAwakeMinBatteryChoices)
    }

    func sleepMac() async -> MacSleepResult {
        await power.sleepNow()
    }

    func setStayAwake(_ mode: StayAwake) -> MacControlRefusal? {
        // Another service owns sleep on this Mac: the setting is greyed out here too.
        guard !power.cloupiPresent else { return .otherService }
        update { $0.stayAwake = mode }
        // With the lid closed only the background helper holds the Mac; macOS asks the person once to allow it.
        if mode == .lidClosed { power.ensureHelperRegistered() }
        return nil
    }

    func setBatteryLimit(_ percent: Int) -> MacControlRefusal? {
        guard !power.cloupiPresent else { return .otherService }
        update { $0.stayAwakeMinBattery = percent }
        return nil
    }

    func updateRoutines(_ change: (inout [Routine]) -> Void) {
        update { change(&$0.routines) }
    }

    static func helperName(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        default: return "notRegistered"
        }
    }
}
