import ActivityKit
import AppIntents
import Foundation

// Shared by the app and its widget extension (AOSWidgets): the Live Activity of the open terminals and its button.

/// The open terminals on the Lock Screen and in the Dynamic Island. Shows which terminals are open and how they
/// are (connected, reconnecting, kept on the Mac), never what they show: the Lock Screen is for anyone to see.
struct TerminalActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        struct Item: Codable, Hashable, Identifiable {
            /// The terminal (TerminalSession.Target's key).
            var id: String
            /// The computer: the Mac's name or the host's.
            var title: String
            /// The shell is held on the Mac and survives the connection.
            var held: Bool
            /// connected, reconnecting, detached
            var state: String
            var since: Date?
        }

        var items: [Item]
        /// What keeps the app running in the background now: "time" (iOS's background time), "location", or nil.
        var keptBy: String?
    }
}

/// The Live Activity's End button. It runs in the app's process (iOS starts the app in the background if needed).
struct EndTerminalIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Terminal Session"
    static let description = IntentDescription("Ends a terminal session of aOS. On the Mac its shell ends too.")
    static let isDiscoverable = false

    @Parameter(title: "Terminal")
    var terminal: String

    init() {}

    init(terminal: String) {
        self.terminal = terminal
    }

    func perform() async throws -> some IntentResult {
        await TerminalActivityActions.end(terminal)
        return .result()
    }
}

/// The app sets what the button does (in the widget extension nothing is set: the intent never runs there).
@MainActor
enum TerminalActivityActions {
    static var onEnd: ((String) async -> Void)?

    static func end(_ terminal: String) async {
        await onEnd?(terminal)
    }
}
