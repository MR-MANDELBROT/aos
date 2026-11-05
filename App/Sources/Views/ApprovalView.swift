import AnnexKit
import SwiftUI

/// "<Agent> wants to open the workspace": shown when the agent itself can't ask the user.
struct ApprovalView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let a = model.approval {
                Label("\(a.agent) wants to open its workspace", systemImage: "macwindow.badge.plus").font(.headline)
                Text(a.purpose).textSelection(.enabled)
                Text("For up to \(a.minutes) minutes. You can watch and close it any time.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Don't allow") { model.answerApproval(a.id, false); dismissWindow(id: WindowID.approval) }
                        .keyboardShortcut(.cancelAction)
                    Button("Allow") { model.answerApproval(a.id, true); dismissWindow(id: WindowID.approval) }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("No request.").foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
