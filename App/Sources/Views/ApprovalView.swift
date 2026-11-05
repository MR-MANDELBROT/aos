import AnnexKit
import SwiftUI

/// "<Agent> wants to open its workspace": shown when the agent itself can't ask the user.
struct ApprovalView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 16) {
            if let a = model.approval {
                AppIconImage(size: 64)
                VStack(spacing: 4) {
                    Text("\(a.agent) wants to open its workspace").font(.title3.bold()).multilineTextAlignment(.center)
                    Text("For up to \(a.minutes) minutes. You can watch and close it any time.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Purpose").font(.caption).foregroundStyle(.secondary)
                        Text(a.purpose).textSelection(.enabled)
                    }
                }
                HStack(spacing: 10) {
                    Button("Don't Allow") { model.answerApproval(a.id, false); dismissWindow(id: WindowID.approval) }
                        .buttonStyle(.glass).keyboardShortcut(.cancelAction)
                        .frame(maxWidth: .infinity)
                    Button("Allow") { model.answerApproval(a.id, true); dismissWindow(id: WindowID.approval) }
                        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                AppIconImage(size: 48)
                Text("No request waiting.").foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
