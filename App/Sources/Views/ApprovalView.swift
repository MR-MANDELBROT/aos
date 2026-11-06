import AOSKit
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
                        .fixedSize(horizontal: false, vertical: true)
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Purpose").font(.caption).foregroundStyle(.secondary)
                        Text(a.purpose).textSelection(.enabled)
                    }
                }
                HStack(spacing: 10) {
                    Button { model.answerApproval(a.id, false); dismissWindow(id: WindowID.approval) } label: {
                        Text("Don't Allow").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass).keyboardShortcut(.cancelAction)
                    Button { model.answerApproval(a.id, true); dismissWindow(id: WindowID.approval) } label: {
                        Text("Allow").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            } else {
                AppIconImage(size: 48)
                Text("No request waiting.").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(width: 380)
    }
}
