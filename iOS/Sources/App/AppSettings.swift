import AOSRFB
import Foundation
import Observation

/// The person's choices. Not secret; kept in UserDefaults.
@MainActor @Observable
final class AppSettings {
    enum FrameRate: String, CaseIterable, Identifiable, Sendable {
        case smooth, balanced, saver
        var id: String { rawValue }
        /// Minimum time between screen pictures.
        var interval: TimeInterval {
            switch self {
            case .smooth: 1.0 / 60
            case .balanced: 1.0 / 30
            case .saver: 0.2
            }
        }
    }

    enum InputMode: String, CaseIterable, Identifiable, Sendable {
        /// One finger moves the pointer like on a trackpad; a tap clicks where the pointer is.
        case trackpad
        /// A tap clicks where the finger is; one finger drags.
        case direct
        var id: String { rawValue }
    }

    /// Picture quality of the screen: a fixed one, or by network (all colours on Wi-Fi, fewer on cellular).
    enum ScreenQuality: String, CaseIterable, Identifiable, Sendable {
        case automatic, best, balanced, saver, gray
        var id: String { rawValue }

        func resolved(cellular: Bool) -> RFBQuality {
            switch self {
            case .automatic: cellular ? .saver : .best
            case .best: .best
            case .balanced: .balanced
            case .saver: .saver
            case .gray: .gray
            }
        }
    }

    /// Who draws the pointer.
    enum PointerStyle: String, CaseIterable, Identifiable, Sendable {
        /// The iPhone: it moves without delay (the agent's own moves don't show).
        case local
        /// The Mac, in the picture: shows where the agent points, moves with the picture's delay.
        case remote
        var id: String { rawValue }
    }

    private let defaults: UserDefaults

    var requireUnlock: Bool { didSet { defaults.set(requireUnlock, forKey: "requireUnlock") } }
    /// Minutes in the background before the app locks again; 0 locks right away.
    var autoLockMinutes: Int { didSet { defaults.set(autoLockMinutes, forKey: "autoLockMinutes") } }

    /// The terminal's font size (pinch to change it).
    var terminalFontSize: Double { didSet { defaults.set(terminalFontSize, forKey: "terminalFontSize") } }
    /// The screen stays on while a terminal is open and connected.
    var terminalKeepsScreenOn: Bool { didSet { defaults.set(terminalKeepsScreenOn, forKey: "terminalKeepsScreenOn") } }

    // MARK: Screen

    var frameRate: FrameRate { didSet { defaults.set(frameRate.rawValue, forKey: "frameRate") } }
    var inputMode: InputMode { didSet { defaults.set(inputMode.rawValue, forKey: "inputMode") } }
    var screenQuality: ScreenQuality { didSet { defaults.set(screenQuality.rawValue, forKey: "screenQuality") } }
    /// How the Mac's own screen (its size can't change) fills the iPhone.
    var macScaling: ScreenGeometry.Scaling { didSet { defaults.set(macScaling.rawValue, forKey: "macScaling") } }
    /// The workspace takes the iPhone's shape while the iPhone shows it.
    var matchWorkspaceShape: Bool { didSet { defaults.set(matchWorkspaceShape, forKey: "matchWorkspaceShape") } }
    /// ... drawn at Retina sharpness (twice the pixels; more data).
    var retinaWorkspace: Bool { didSet { defaults.set(retinaWorkspace, forKey: "retinaWorkspace") } }
    var pointerStyle: PointerStyle { didSet { defaults.set(pointerStyle.rawValue, forKey: "pointerStyle") } }
    /// Trackpad speed: 0.5 ... 2.
    var pointerSpeed: Double { didSet { defaults.set(pointerSpeed, forKey: "pointerSpeed") } }
    /// Content follows the fingers (like the Mac's default); off: the wheel's direction.
    var naturalScrolling: Bool { didSet { defaults.set(naturalScrolling, forKey: "naturalScrolling") } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    /// The toolbar of the screen hides after a few seconds.
    var autoHideToolbar: Bool { didSet { defaults.set(autoHideToolbar, forKey: "autoHideToolbar") } }
    /// The row with Esc, Tab, modifier and arrow keys above the keyboard.
    var showsKeyBar: Bool { didSet { defaults.set(showsKeyBar, forKey: "showsKeyBar") } }
    /// Picture rate, data and delay on the screen.
    var showsScreenStats: Bool { didSet { defaults.set(showsScreenStats, forKey: "showsScreenStats") } }

    static let autoLockChoices = [0, 1, 5, 15, 60]
    static let pointerSpeedRange = 0.5...2.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // bool(forKey:) also reads "YES"/"NO" (launch arguments for tests and screenshots).
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key) }
        requireUnlock = bool("requireUnlock", false)
        autoLockMinutes = defaults.object(forKey: "autoLockMinutes") as? Int ?? 5
        terminalFontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 13
        terminalKeepsScreenOn = defaults.object(forKey: "terminalKeepsScreenOn") as? Bool ?? false
        frameRate = FrameRate(rawValue: defaults.string(forKey: "frameRate") ?? "") ?? .smooth
        inputMode = InputMode(rawValue: defaults.string(forKey: "inputMode") ?? "") ?? .trackpad
        screenQuality = ScreenQuality(rawValue: defaults.string(forKey: "screenQuality") ?? "") ?? .automatic
        macScaling = ScreenGeometry.Scaling(rawValue: defaults.string(forKey: "macScaling") ?? "") ?? .fit
        matchWorkspaceShape = bool("matchWorkspaceShape", true)
        retinaWorkspace = bool("retinaWorkspace", true)
        pointerStyle = PointerStyle(rawValue: defaults.string(forKey: "pointerStyle") ?? "") ?? .local
        let speed = defaults.object(forKey: "pointerSpeed") as? Double ?? 1
        pointerSpeed = min(max(speed, Self.pointerSpeedRange.lowerBound), Self.pointerSpeedRange.upperBound)
        naturalScrolling = bool("naturalScrolling", true)
        haptics = bool("haptics", true)
        autoHideToolbar = bool("autoHideToolbar", true)
        showsKeyBar = bool("showsKeyBar", true)
        showsScreenStats = bool("showsScreenStats", false)
    }
}
