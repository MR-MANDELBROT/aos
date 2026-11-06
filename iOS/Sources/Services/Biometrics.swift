import Foundation
import LocalAuthentication

/// Face ID (or Touch ID, or the device passcode as fallback) in front of secrets and approvals.
enum Biometrics {
    enum Kind: Sendable { case faceID, touchID, opticID, passcodeOnly, unavailable }

    static var kind: Kind {
        let context = LAContext()
        var error: NSError?
        let canBiometrics = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        if canBiometrics || context.biometryType != .none {
            switch context.biometryType {
            case .faceID: return .faceID
            case .touchID: return .touchID
            case .opticID: return .opticID
            default: break
            }
        }
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) ? .passcodeOnly : .unavailable
    }

    /// "Face ID", "Touch ID", ... for labels like "Approve with Face ID".
    static var name: String {
        switch kind {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .passcodeOnly, .unavailable: String(localized: "Passcode")
        }
    }

    static var symbol: String {
        switch kind {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .passcodeOnly, .unavailable: "lock"
        }
    }

    enum Failure: Error, Equatable { case cancelled, failed, unavailable }

    /// Asks for Face ID (falling back to the passcode). The returned context unlocks keychain items behind user
    /// presence without asking again; invalidate it when done.
    static func authenticate(reason: String) async throws -> LAContext {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { throw Failure.unavailable }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard ok else { throw Failure.failed }
            return context
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel: throw Failure.cancelled
            case .passcodeNotSet, .biometryNotAvailable: throw Failure.unavailable
            default: throw Failure.failed
            }
        }
    }
}
