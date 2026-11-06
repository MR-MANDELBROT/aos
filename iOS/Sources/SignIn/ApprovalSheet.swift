import SwiftUI

/// An agent that can't ask by itself wants to open the workspace. The person sees who, why and for how long, and
/// allows it or not.
struct ApprovalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ApprovalRequest

    enum Phase: Equatable { case asking, sending, answered(Bool), failed(String) }

    @State private var phase: Phase = .asking

    private var result: ApprovalResult? { model.approvalResults[request.id] }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let expired = request.expires.map { $0 <= context.date } ?? false
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(now: context.date, expired: expired)
                        if let result {
                            outcome(allowed: result == .allowed)
                        } else if expired {
                            notice(symbol: "clock.badge.xmark", text: "This request has expired.", tint: .secondary)
                        } else {
                            switch phase {
                            case .asking, .failed: buttons
                            case .sending: ProgressView("Sending …").frame(maxWidth: .infinity)
                            case .answered(let allowed): outcome(allowed: allowed)
                            }
                            if case .failed(let message) = phase {
                                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.subheadline)
                            }
                        }
                        FactRow(symbol: "macwindow.on.rectangle",
                                text: "The workspace is a Mac of its own in a virtual machine, separate from yours. It closes again when the time is up.")
                    }
                    .padding()
                }
            }
            .annexBackground()
            .navigationTitle("Workspace request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
            }
        }
    }

    private func header(now: Date, expired: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("\(request.agent.isEmpty ? String(localized: "Your agent") : request.agent) wants to open the workspace")
            } icon: {
                Image(systemName: "macwindow.badge.plus")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(BrandColor.attention)

            Text(request.purpose.isEmpty ? String(localized: "Open the workspace") : "\u{201E}\(request.purpose)\u{201C}")
                .font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                if let minutes = request.minutes, minutes > 0 {
                    Label("For \(minutes) minutes", systemImage: "hourglass")
                }
                if let expires = request.expires, result == nil {
                    let left = max(0, Int(expires.timeIntervalSince(now)))
                    Label {
                        Text(expired ? String(localized: "Expired") : String(localized: "\(left / 60):\(String(format: "%02d", left % 60)) left"))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "timer")
                    }
                    .foregroundStyle(left < 30 ? .orange : .secondary)
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await answer(true) }
            } label: {
                Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Button(role: .destructive) {
                Task { await answer(false) }
            } label: {
                Label("Don't Allow", systemImage: "hand.raised").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    private func outcome(allowed: Bool) -> some View {
        allowed
            ? notice(symbol: "checkmark.circle.fill", text: "Allowed. The workspace opens.", tint: .green)
            : notice(symbol: "hand.raised.fill", text: "Not allowed. The workspace stays closed.", tint: .secondary)
    }

    private func notice(symbol: String, text: LocalizedStringKey, tint: Color) -> some View {
        GlassCard {
            Label {
                Text(text).font(.headline)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
        }
    }

    private func answer(_ allowed: Bool) async {
        guard let connection = model.connection else { return }
        phase = .sending
        do {
            try await connection.answerApproval(request: request.id, allowed: allowed)
            phase = .answered(allowed)
            Task {
                try? await Task.sleep(for: .seconds(4))
                if model.presentedQuestion?.id == request.id { dismiss() }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
