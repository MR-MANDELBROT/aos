import Foundation

/// The model and effort a delivery wants in the session (a routine's own); nil fields: the session's own.
public struct SessionSetup: Codable, Sendable, Equatable {
    public var model: String?
    public var effort: String?

    public init(model: String? = nil, effort: String? = nil) {
        self.model = model?.isEmpty == true ? nil : model
        self.effort = effort?.isEmpty == true ? nil : effort
    }

    public var isEmpty: Bool { model == nil && effort == nil }
}

/// One line aOS types into the session before a delivery: Claude Code's `/model` or `/effort` command.
struct SetupLine: Equatable {
    enum Kind: Equatable { case model, effort }
    var kind: Kind
    /// The command's argument ("sonnet", "default", "high", "auto").
    var value: String

    var text: String { "/\(kind == .model ? "model" : "effort") \(value)" }
}

/// Which commands go into the session before a delivery. `applied` is what aOS set with its own commands since the
/// session started (nil fields: still the session's own); a delivery without a model or an effort goes back to the
/// session's own (`/model default`, and `/effort` with the session's effort from the settings or `auto`). Nothing is
/// typed when nothing changes.
enum SessionSetupPlan {
    static func lines(want: SessionSetup, applied: SessionSetup, sessionEffort: String) -> (lines: [SetupLine], applied: SessionSetup) {
        var lines: [SetupLine] = []
        var now = applied
        let ownEffort = sessionEffort.isEmpty ? nil : sessionEffort
        if let m = want.model {
            if applied.model?.lowercased() != m.lowercased() {
                lines.append(SetupLine(kind: .model, value: m))
                now.model = m
            }
        } else if applied.model != nil {
            lines.append(SetupLine(kind: .model, value: "default"))
            now.model = nil
        }
        if let e = want.effort {
            // The session's own effort already is this one: nothing to type, and nothing to undo later
            if (applied.effort ?? ownEffort) != e {
                lines.append(SetupLine(kind: .effort, value: e))
                now.effort = e == ownEffort ? nil : e
            }
        } else if applied.effort != nil {
            lines.append(SetupLine(kind: .effort, value: ownEffort ?? "auto"))
            now.effort = nil
        }
        return (lines, now)
    }

    /// What Claude Code's output says about a command aOS typed: it answered (done), it asks to confirm switching
    /// the model because the conversation's cache is warm (confirm: Enter, its default is "Yes"), it shows another
    /// question aOS must not answer for the user (refuse: Escape), or nothing yet.
    enum Reply: Equatable { case none, done, confirm, refuse }

    static func reply(to kind: SetupLine.Kind, in output: String) -> Reply {
        let text = output.lowercased().filter { !$0.isWhitespace }
        if kind == .model {
            if text.contains("switchmodel?"), text.contains("nextresponsewillbeslower") { return .confirm }
            // Usage credits (Fable) or a PreModelSwitch hook that wants a person: not for aOS to accept
            if text.contains("usagecredits") || text.contains("hookaskedyoutoconfirm") { return .refuse }
            let answers = ["setmodelto", "modelsetto", "keptmodelas", "currentmodel:", "couldn'tswitchmodel",
                           "couldn'tconfirmmodel", "modelswitchblocked", "wasblockedbyapremodelswitchhook",
                           "usage:/model", "failedtovalidatemodel", "notfound", "isn'tavailable", "notavailable"]
            return answers.contains { text.contains($0) } ? .done : .none
        }
        let answers = ["seteffortlevelto", "effortlevelsetto", "effortsettoauto", "clearedeffort", "notapplied:",
                       "unknownoption:", "couldn'tseteffortlevel", "exceedsthecap", "can'tbesetonaremotesession",
                       "usage:/effort", "overridesthissession"]
        return answers.contains { text.contains($0) } ? .done : .none
    }
}

/// Claude Code's own user settings (~/.claude/settings.json). In an interactive session `/model X` and `/effort X`
/// also save X as the default for new sessions there; aOS's routines must not change the user's defaults, so aOS
/// notes the two values before its command and puts them back right after Claude Code wrote them. Only the line of
/// that key changes (the rest of the file stays as Claude Code wrote it).
struct ClaudeUserSettings {
    let url: URL

    static var standard: ClaudeUserSettings {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let dir = env.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return ClaudeUserSettings(url: dir.appendingPathComponent("settings.json"))
    }

    /// The settings key a command writes.
    static func key(_ kind: SetupLine.Kind) -> String { kind == .model ? "model" : "effortLevel" }

    /// The file's top-level object; nil when there is no file or it isn't a JSON object (then aOS leaves it alone).
    func read() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// The value of a key: .some(nil) when it isn't set, nil when the file can't be read or the value isn't text.
    func value(_ key: String) -> String?? {
        guard let object = read() else { return nil }
        guard let v = object[key] else { return .some(nil) }
        return (v as? String).map { .some($0) }
    }

    /// Sets a key to a text (nil: removes it). Edits only that key's line when the file has Claude Code's layout
    /// (two spaces of indentation); else writes the whole object again.
    @discardableResult
    func set(_ key: String, to value: String?) -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        if let value { object[key] = value } else { object[key] = nil }
        var out = Self.edit(text, key: key, value: value)
        if let edited = out, !Self.same(edited, object) { out = nil }
        if out == nil {
            guard let whole = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]),
                  let s = String(data: whole, encoding: .utf8) else { return false }
            out = s + "\n"
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let out, (try? Data(out.utf8).write(to: url, options: .atomic)) != nil else { return false }
        if let perms = attributes?[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
        }
        return true
    }

    private static func same(_ text: String, _ object: [String: Any]) -> Bool {
        guard let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return false }
        return NSDictionary(dictionary: parsed).isEqual(to: object)
    }

    private static func encoded(_ s: String) -> String? {
        (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The file with one top-level key's line changed, removed or added; nil when its layout isn't the expected one.
    static func edit(_ text: String, key: String, value: String?) -> String? {
        var lines = text.components(separatedBy: "\n")
        let prefix = "  \"\(key)\": "
        let index = lines.firstIndex { $0.hasPrefix(prefix) }
        if let i = index {
            let rest = lines[i].dropFirst(prefix.count)
            // Only a value on one line (text, number, true/false)
            guard let last = rest.last, last != "{", last != "[" else { return nil }
            let comma = rest.hasSuffix(",")
            if let value {
                guard let v = encoded(value) else { return nil }
                lines[i] = prefix + v + (comma ? "," : "")
            } else {
                lines.remove(at: i)
                if !comma, let p = lines[..<i].lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                   lines[p].hasSuffix(",") {
                    lines[p].removeLast()
                }
            }
            return lines.joined(separator: "\n")
        }
        guard let value else { return text }
        guard let v = encoded(value) else { return nil }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" {
            return "{\n" + prefix + v + "\n}\n"
        }
        guard let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "{" }), open == 0 else { return nil }
        lines.insert(prefix + v + ",", at: open + 1)
        return lines.joined(separator: "\n")
    }
}
