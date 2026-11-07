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
    /// The arrows in the middle of the key bar: the swipe pad or four keys.
    var terminalArrowKeys: TerminalArrowKeys { didSet { defaults.set(terminalArrowKeys.rawValue, forKey: "terminalArrowKeys") } }
    /// Swiping on the terminal sends arrow keys (TerminalSwipe).
    var terminalSwipeArrows: Bool { didSet { defaults.set(terminalSwipeArrows, forKey: "terminalSwipeArrows") } }
    /// The open terminals in a Live Activity (Lock Screen, Dynamic Island).
    var terminalLiveActivity: Bool { didSet { defaults.set(terminalLiveActivity, forKey: "terminalLiveActivity") } }
    /// iOS's continued processing task while a terminal is open (more time in the background, with iOS's progress).
    var terminalBackgroundTime: Bool { didSet { defaults.set(terminalBackgroundTime, forKey: "terminalBackgroundTime") } }
    /// The location service keeps the app running in the background while a terminal is open (costs battery).
    var terminalKeepAliveLocation: Bool { didSet { defaults.set(terminalKeepAliveLocation, forKey: "terminalKeepAliveLocation") } }

    // MARK: Screen

    /// Both screens take the iPhone's shape while the iPhone shows them: the workspace through aOS's display request,
    /// the Mac through Open Screen Sharing's virtual display (direct path, high performance).
    var screenMatchesPhone: Bool { didSet { defaults.set(screenMatchesPhone, forKey: "screenMatchesPhone") } }
    /// Open Screen Sharing's resolution for both (1x to 2x): more room, less sharp.
    var screenResolution: Double { didSet { defaults.set(screenResolution, forKey: "screenResolution") } }

    static let autoLockChoices = [0, 1, 5, 15, 60]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // bool(forKey:) also reads "YES"/"NO" (launch arguments for tests and screenshots).
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key) }
        requireUnlock = bool("requireUnlock", false)
        autoLockMinutes = defaults.object(forKey: "autoLockMinutes") as? Int ?? 5
        terminalFontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 13
        terminalKeepsScreenOn = defaults.object(forKey: "terminalKeepsScreenOn") as? Bool ?? false
        terminalArrowKeys = TerminalArrowKeys(rawValue: defaults.string(forKey: "terminalArrowKeys") ?? "") ?? .pad
        terminalSwipeArrows = bool("terminalSwipeArrows", true)
        terminalLiveActivity = bool("terminalLiveActivity", true)
        terminalBackgroundTime = bool("terminalBackgroundTime", true)
        terminalKeepAliveLocation = bool("terminalKeepAliveLocation", false)
        // Before: the workspace alone took the iPhone's shape ("matchWorkspaceShape")
        screenMatchesPhone = bool("screenMatchesPhone", bool("matchWorkspaceShape", true))
        let resolution = defaults.double(forKey: "screenResolution")
        screenResolution = (1...2).contains(resolution) ? resolution : 1
    }
}
