import SwiftUI

/// aOS's session's default model and effort on the Mac (`session.defaults`): they apply the next time the session
/// starts, and changing them never restarts it. The session's restart (with its confirmation) is here for when it
/// should start now. Shown only while the Mac reports them (an older aOS doesn't).
struct SessionDefaultsPage: View {
    @Environment(AppModel.self) private var model
    @State private var actions = ActionState()
    /// The choice on its way to the Mac (the pickers show it until the Mac's answer).
    @State private var pending: MacStatus.SessionDefaults?
    @State private var confirmRestart = false

    private var connection: MacConnection? { model.connection }
    private var session: MacStatus.Session? { connection?.macStatus?.session }

    var body: some View {
        List {
            if let session, let current = session.defaults {
                let shown = pending ?? current
                Section {
                    Picker("Model", selection: Binding(get: { shown.model }, set: { m in
                        var d = shown
                        d.model = m
                        save(d)
                    })) {
                        ForEach(SessionDefaultsText.choices(MacStatus.SessionDefaults.models, including: shown.model),
                                id: \.self) { m in
                            Text(SessionDefaultsText.model(m)).tag(m)
                        }
                    }
                    Picker("Effort", selection: Binding(get: { shown.effort }, set: { e in
                        var d = shown
                        d.effort = e
                        save(d)
                    })) {
                        ForEach(SessionDefaultsText.choices(MacStatus.SessionDefaults.efforts, including: shown.effort),
                                id: \.self) { e in
                            Text(SessionDefaultsText.effort(e)).tag(e)
                        }
                    }
                } footer: {
                    Text("Applies the next time the session starts. Changing it doesn't restart the session.")
                }
                .disabled(actions.running != nil)
                if session.enabled, session.state != nil {
                    Section {
                        Button("Restart Session …", systemImage: "arrow.clockwise") { confirmRestart = true }
                            .disabled(actions.running != nil)
                    }
                }
            } else {
                ContentUnavailableView("Not available", systemImage: "slider.horizontal.3",
                                       description: Text("Connect to your Mac, and update aOS there if it's older."))
            }
        }
        .navigationTitle("Session Default")
        .safeAreaInset(edge: .bottom) {
            if let problem = actions.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(in: Capsule())
                    .padding(.bottom, 8)
            }
        }
        // Answered or refused: the pickers show the Mac's values again
        .onChange(of: actions.running) { _, running in if running == nil { pending = nil } }
        .refreshable { await connection?.refreshMacStatus() }
        .task { await connection?.refreshMacStatus() }
        .confirmationDialog("Restart the Claude Code session?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart") { if let connection { actions.run(.sessionRestart, on: connection) } }
        } message: {
            Text("aOS on the Mac starts Claude Code again. The conversation continues where it was.")
        }
    }

    private func save(_ d: MacStatus.SessionDefaults) {
        guard let connection, d != (pending ?? session?.defaults) else { return }
        pending = d
        actions.run(.sessionDefaults, value: d.json, on: connection)
    }
}

/// The session's model and effort in words.
enum SessionDefaultsText {
    /// The choices, with the Mac's own value when it is another one (a newer aOS).
    static func choices(_ list: [String], including current: String) -> [String] {
        list.contains(current) ? list : list + [current]
    }

    static func model(_ m: String) -> String {
        switch m {
        case "": String(localized: "Claude Code's default")
        case "opus": "Opus"
        case "opus[1m]": String(localized: "Opus (1M context)")
        case "sonnet": "Sonnet"
        case "sonnet[1m]": String(localized: "Sonnet (1M context)")
        case "haiku": "Haiku"
        default: m
        }
    }

    static func effort(_ e: String) -> String {
        switch e {
        case "": String(localized: "Claude Code's default")
        case "low": String(localized: "Low")
        case "medium": String(localized: "Medium")
        case "high": String(localized: "High")
        case "xhigh": String(localized: "Extra high")
        case "max": String(localized: "Max")
        default: e
        }
    }

    /// The Overview's line: "Claude Code's default", or "Opus (1M context), High effort", "Sonnet", "High effort".
    static func summary(_ d: MacStatus.SessionDefaults) -> String {
        switch (d.model.isEmpty, d.effort.isEmpty) {
        case (true, true): String(localized: "Claude Code's default")
        case (false, true): model(d.model)
        case (true, false): String(localized: "\(effort(d.effort)) effort")
        case (false, false): String(localized: "\(model(d.model)), \(effort(d.effort)) effort")
        }
    }
}
