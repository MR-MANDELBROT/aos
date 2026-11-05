import Foundation
import IOKit.pwr_mgt

/// Holds a power assertion so the Mac doesn't fall asleep while idle (the session must stay reachable).
/// Closing a laptop's lid still sleeps it; macOS allows no app to prevent that.
@MainActor
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private(set) var active = false

    func set(_ on: Bool) {
        if on == active { return }
        if on {
            let reason = "Keeps the Claude session reachable" as CFString
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess {
                active = true
            }
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
            active = false
        }
    }
}
