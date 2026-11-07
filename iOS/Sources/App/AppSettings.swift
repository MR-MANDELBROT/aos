import Foundation
import Observation

/// The person's choices. Not secret; kept in UserDefaults. (The screen's own settings, Open Screen Sharing's, are
/// kept by the screen client: Settings > Screen.)
@MainActor @Observable
final class AppSettings {
    private let defaults: UserDefaults

    var requireUnlock: Bool { didSet { defaults.set(requireUnlock, forKey: "requireUnlock") } }
    /// Minutes in the background before the app locks again; 0 locks right away.
    var autoLockMinutes: Int { didSet { defaults.set(autoLockMinutes, forKey: "autoLockMinutes") } }

    /// The terminal's font size (pinch to change it).
    var terminalFontSize: Double { didSet { defaults.set(terminalFontSize, forKey: "terminalFontSize") } }
    /// The screen stays on while a terminal is open and connected.
    var terminalKeepsScreenOn: Bool { didSet { defaults.set(terminalKeepsScreenOn, forKey: "terminalKeepsScreenOn") } }

    // MARK: Screen

    /// The workspace takes the iPhone's shape while the iPhone shows it.
    var matchWorkspaceShape: Bool { didSet { defaults.set(matchWorkspaceShape, forKey: "matchWorkspaceShape") } }
    /// ... drawn at Retina sharpness (twice the pixels; more data).
    var retinaWorkspace: Bool { didSet { defaults.set(retinaWorkspace, forKey: "retinaWorkspace") } }

    static let autoLockChoices = [0, 1, 5, 15, 60]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // bool(forKey:) also reads "YES"/"NO" (launch arguments for tests and screenshots).
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key) }
        requireUnlock = bool("requireUnlock", false)
        autoLockMinutes = defaults.object(forKey: "autoLockMinutes") as? Int ?? 5
        terminalFontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 13
        terminalKeepsScreenOn = defaults.object(forKey: "terminalKeepsScreenOn") as? Bool ?? false
        matchWorkspaceShape = bool("matchWorkspaceShape", true)
        retinaWorkspace = bool("retinaWorkspace", true)
    }
}
