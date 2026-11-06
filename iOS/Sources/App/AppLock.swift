import Foundation
import Observation
import SwiftUI

/// "Require Face ID to open Annex": locks at launch and after the chosen time in the background.
@MainActor @Observable
final class AppLock {
    private(set) var isLocked: Bool
    private(set) var isUnlocking = false
    var failureMessage: String?
    private var backgroundedAt: Date?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        isLocked = settings.requireUnlock
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            if backgroundedAt == nil { backgroundedAt = Date() }
        case .active:
            defer { backgroundedAt = nil }
            guard settings.requireUnlock, let since = backgroundedAt else { return }
            if Date().timeIntervalSince(since) >= Double(settings.autoLockMinutes * 60) { isLocked = true }
        default:
            break
        }
    }

    func unlock() async {
        guard isLocked, !isUnlocking else { return }
        isUnlocking = true
        defer { isUnlocking = false }
        do {
            let context = try await Biometrics.authenticate(reason: String(localized: "Unlock Annex"))
            context.invalidate()
            isLocked = false
            failureMessage = nil
        } catch Biometrics.Failure.unavailable {
            // No passcode on this iPhone: the lock can't work, so it doesn't block.
            isLocked = false
        } catch Biometrics.Failure.cancelled {
            failureMessage = nil
        } catch {
            failureMessage = String(localized: "Unlocking didn't work. Try again.")
        }
    }

    #if DEBUG
    func lockForDemo() { isLocked = true }
    #endif

    /// Turning the lock on asks for Face ID first, so nobody locks the owner out by accident.
    func setRequired(_ required: Bool) async -> Bool {
        if required {
            do {
                let context = try await Biometrics.authenticate(reason: String(localized: "Turn on Face ID for Annex"))
                context.invalidate()
            } catch {
                return false
            }
        }
        settings.requireUnlock = required
        return true
    }
}
