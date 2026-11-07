// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import SwiftUI

struct AlertState {
    struct Action {
        var label: String
        var role: ButtonRole?
        var isDefault = false
        var perform: () -> Void
    }

    var title: String
    var message: String
    var actions: [Action]

    init(title: String, message: String = "", actions: [Action] = [Action(label: String(localized: "OK"), role: .cancel) {}]) {
        self.title = title
        self.message = message
        self.actions = actions
    }

    init(_ failure: String, error: (any Error)?) {
        self.init(failure, errorMessage: error?.localizedDescription ?? "")
    }

    init(_ failure: String, errorMessage: String, closeLabel: String = String(localized: "OK"), onClose: @escaping () -> Void = {}) {
        let message = errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        var actions = [Action(label: closeLabel, role: .cancel, isDefault: true, perform: onClose)]
        if !message.isEmpty {
            actions.insert(
                Action(label: String(localized: "Copy"), role: nil) {
                    ClipboardAccess.shared.write("\(failure)\n\(message)")
                    onClose()
                }, at: 0)
        }
        self.init(title: failure, message: message, actions: actions)
    }
}

extension View {
    func alert(_ state: Binding<AlertState?>) -> some View {
        alert(
            state.wrappedValue?.title ?? "",
            isPresented: Binding(get: { state.wrappedValue != nil }, set: { if !$0 { state.wrappedValue = nil } }),
            presenting: state.wrappedValue
        ) { alert in
            ForEach(alert.actions.indices, id: \.self) { index in
                let action = alert.actions[index]
                #if os(macOS)
                Button(action.label, role: action.role, action: action.perform)
                    .keyboardShortcut(action.isDefault ? .defaultAction : nil)
                #else
                Button(action.label, role: action.role, action: action.perform)
                #endif
            }
        } message: { alert in
            if !alert.message.isEmpty {
                Text(alert.message)
            }
        }
    }
}

nonisolated struct MessageError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    init(_ operation: String, status: OSStatus) {
        message = "\(operation): OSStatus \(status)"
    }

    var errorDescription: String? { message }
}
