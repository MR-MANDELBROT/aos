// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import Perception
import SwiftUI
import os

@Perceptible
final class StorageNotice {
    static let shared = StorageNotice()

    nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenScreenSharing", category: "storage")

    private(set) var alert: AlertState?
    @PerceptionIgnored private var queued: [AlertState] = []

    func report(_ failure: String, error: any Error) {
        Self.logger.error("\(failure, privacy: .public): \(error, privacy: .public)")
        let alert = AlertState(failure, error: error)
        guard !([self.alert].compactMap(\.self) + queued).contains(where: { $0.title == alert.title && $0.message == alert.message }) else { return }
        if self.alert == nil {
            self.alert = alert
        } else {
            queued.append(alert)
        }
    }

    fileprivate func dismiss() {
        alert = nil
        guard !queued.isEmpty else { return }
        DispatchQueue.main.async { [self] in
            guard alert == nil, !queued.isEmpty else { return }
            alert = queued.removeFirst()
        }
    }
}

struct StorageNoticeAlert: ViewModifier {
    private let notice = StorageNotice.shared

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content.alert(Binding(get: { notice.alert }, set: { if $0 == nil { notice.dismiss() } }))
        }
    }
}
