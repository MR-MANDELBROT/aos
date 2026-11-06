import Foundation

/// The command line for the companion's exec channel. sshd hands exec commands to the login shell, so the path is
/// quoted for it.
enum CompanionCommand {
    static let defaultPath = "/Applications/aOS.app/Contents/MacOS/aos-companion"

    static func serve(path: String) -> String {
        shellQuoted(path) + " serve"
    }

    /// `'...'` with embedded single quotes written as `'\''`.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
