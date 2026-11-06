import AOSKit
import AppKit
import Foundation

/// The user's Bitwarden account (AOSKit's BitwardenVault): what the settings, the sign-in window and the menu show.
extension AppModel {
    var bitwarden: BitwardenVault { workspace.bitwarden }

    /// At launch: the account's state, and locking when the Mac goes to sleep.
    func startBitwarden() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await AppModel.shared.bitwarden.lock(reason: "the Mac goes to sleep") }
        }
        Task { await bitwarden.refresh() }
    }

    func signInToBitwarden(email: String, password: String, server: BitwardenServer) {
        Task { await bitwarden.signIn(email: email, password: password, server: server) }
    }

    func unlockBitwarden(password: String) {
        Task { await bitwarden.unlock(password: password) }
    }

    func lockBitwarden() {
        Task { await bitwarden.lock(reason: "locked by the user") }
    }

    func signOutOfBitwarden() {
        Task { await bitwarden.signOut() }
    }

    /// A sign-in answered on the Mac with a Bitwarden login: aOS gets it from Bitwarden and fills it.
    func answerSignIn(_ event: CompanionEvent, login: String) {
        guard let id = event.request else { return }
        workspace.answerSignIn(id, SignInAnswer(login: login, from: "Mac"))
    }

    /// The phase in a few words (menu, settings).
    var bitwardenStateText: String {
        switch bitwarden.phase {
        case .unlocked:
            if let until = bitwarden.lockedAt {
                return String(localized: "Unlocked until \(until.formatted(date: .omitted, time: .shortened))")
            }
            return String(localized: "Unlocked")
        case .locked, .unlocking: return String(localized: "Locked")
        case .signingIn: return String(localized: "Signing in …")
        case .installing: return String(localized: "Downloading Bitwarden's command line tool …")
        case .signedOut, .noTool: return String(localized: "Not signed in")
        case .unknown: return String(localized: "Checking …")
        }
    }

    /// What went wrong, in words (Bitwarden's own messages stay as Bitwarden wrote them).
    func bitwardenProblemText(_ error: Error) -> String {
        if let error = error as? BitwardenError {
            switch error {
            case .notRunnable(let detail):
                return String(localized: "Bitwarden's command line tool could not be started (\(detail)).")
            case .timeout: return String(localized: "Bitwarden didn't answer in time. Check the internet connection and try again.")
            case .locked: return String(localized: "Bitwarden is locked.")
            case .notLoggedIn: return String(localized: "Not signed in to Bitwarden.")
            case .notFound: return String(localized: "Bitwarden doesn't have this login (any more).")
            case .notALogin: return String(localized: "This Bitwarden item isn't a login.")
            case .wrongPassword: return String(localized: "The master password isn't right.")
            case .invalidEmail: return String(localized: "That isn't an email address.")
            case .cancelled: return String(localized: "Cancelled.")
            case .failed(let message): return message
            case .unexpected(let detail):
                return String(localized: "Bitwarden's command line tool answered unexpectedly (\(detail)).")
            }
        }
        if let error = error as? BitwardenTool.InstallError {
            switch error {
            case .noRelease(let detail):
                return String(localized: "Bitwarden's download link didn't lead to a release (\(detail)).")
            case .download(let detail):
                return String(localized: "Bitwarden's command line tool could not be downloaded (\(detail)).")
            case .notBitwarden(let detail):
                return String(localized: "The download isn't Bitwarden's signed command line tool (\(detail)), so \(Brand.name) deleted it.")
            }
        }
        return error.localizedDescription
    }

    /// Bitwarden's name for a two-step method, in the user's language where it is one Bitwarden has.
    static func twoStepMethodName(_ name: String) -> String {
        switch name {
        case "Authenticator App": return String(localized: "Authenticator app")
        case "Email": return String(localized: "Email")
        case "Yubico OTP Security Key": return String(localized: "YubiKey (one-time password)")
        default: return name
        }
    }
}
