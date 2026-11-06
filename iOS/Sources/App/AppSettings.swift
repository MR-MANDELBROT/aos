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
            case .smooth: 0.05
            case .balanced: 0.1
            case .saver: 0.3
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

    private let defaults: UserDefaults

    var requireUnlock: Bool { didSet { defaults.set(requireUnlock, forKey: "requireUnlock") } }
    /// Minutes in the background before the app locks again; 0 locks right away.
    var autoLockMinutes: Int { didSet { defaults.set(autoLockMinutes, forKey: "autoLockMinutes") } }
    var frameRate: FrameRate { didSet { defaults.set(frameRate.rawValue, forKey: "frameRate") } }
    var inputMode: InputMode { didSet { defaults.set(inputMode.rawValue, forKey: "inputMode") } }

    static let autoLockChoices = [0, 1, 5, 15, 60]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        requireUnlock = defaults.object(forKey: "requireUnlock") as? Bool ?? false
        autoLockMinutes = defaults.object(forKey: "autoLockMinutes") as? Int ?? 5
        frameRate = FrameRate(rawValue: defaults.string(forKey: "frameRate") ?? "") ?? .balanced
        inputMode = InputMode(rawValue: defaults.string(forKey: "inputMode") ?? "") ?? .trackpad
    }
}
