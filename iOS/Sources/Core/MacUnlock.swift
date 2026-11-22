import Foundation
import ScreenClient

/// Whether aOS may type the Mac's saved password into the Mac's lock screen (`ScreenSession`'s unlock, iOS/NOTES.md
/// "Unlocking the Mac"). Only when everything says it goes into the lock screen's password field: the Mac reports this
/// user's screen locked (`mac.status` `screen`, asked right before), the saved login is for that account, the Mac
/// reports secure input (a password field has the keyboard), and the password can be typed there. Any doubt is a
/// skip. Pure, tested in MacUnlockTests.
enum MacUnlock {
    enum Verdict: Equatable, Sendable {
        case type
        case skip(Skip)
    }

    enum Skip: Equatable, Sendable {
        /// The Mac didn't say (an older aOS, no answer, a state this app doesn't know).
        case unknown
        case unlocked
        /// Another session, or the login window, is on the Mac's screen.
        case away
        /// The lock screen is for another account (its name) than the saved login's.
        case otherAccount(String)
        /// The Mac doesn't report a password field with the keyboard.
        case noPasswordField
        /// Characters a Mac password field doesn't take over screen sharing.
        case unsupportedCharacters

        /// Worth a message: the Mac is locked, aOS didn't type. (Unlocked, away and unknown say nothing.)
        var isWorthSaying: Bool {
            switch self {
            case .unknown, .unlocked, .away: false
            case .otherAccount, .noPasswordField, .unsupportedCharacters: true
            }
        }
    }

    /// The decision right before typing: `lock` as the Mac reported it just now, the saved login, and whether the
    /// session reports secure input now.
    static func verdict(lock: MacStatus.ScreenLock?, username: String, password: String, secureInput: Bool) -> Verdict {
        guard let lock else { return .skip(.unknown) }
        switch lock.state {
        case "locked": break
        case "unlocked": return .skip(.unlocked)
        case "away": return .skip(.away)
        default: return .skip(.unknown)
        }
        guard isAccount(of: lock, username) else { return .skip(.otherAccount(lock.user)) }
        guard canType(password) else { return .skip(.unsupportedCharacters) }
        guard secureInput else { return .skip(.noPasswordField) }
        return .type
    }

    /// The saved login is for the locked session's account: its account name or its full name (screen sharing takes
    /// either), ignoring case and surrounding spaces.
    static func isAccount(of lock: MacStatus.ScreenLock, _ username: String) -> Bool {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        return [lock.user, lock.name ?? ""].contains { !$0.isEmpty && $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Printable ASCII only, as Open Screen Sharing types into a Mac password field.
    static func canType(_ password: String) -> Bool { ScreenClientSession.canType(password: password) }

    /// After typing: unlocked worked, still locked didn't (no second try: a wrong password typed again and again
    /// locks accounts), anything else is unknown.
    enum Outcome: Equatable, Sendable {
        case unlocked, stillLocked, unknown
    }

    static func outcome(_ lock: MacStatus.ScreenLock?) -> Outcome {
        switch lock?.state {
        case "unlocked"?: .unlocked
        case "locked"?: .stillLocked
        default: .unknown
        }
    }
}
