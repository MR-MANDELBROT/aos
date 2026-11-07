// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import Foundation
import Libsharing
import os

nonisolated final class LibsharingLog: NSObject, LibsharingLogHandlerProtocol {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenScreenSharing", category: "libsharing")

    static let installed: Void = LibsharingSetLogHandler(LibsharingLog(), -4)

    func log(_ level: Int32, message: String?) {
        let text = message ?? ""
        switch level {
        case ..<0: Self.logger.debug("\(text, privacy: .public)")
        case ..<4: Self.logger.info("\(text, privacy: .public)")
        case ..<8: Self.logger.warning("\(text, privacy: .public)")
        default: Self.logger.error("\(text, privacy: .public)")
        }
    }
}
