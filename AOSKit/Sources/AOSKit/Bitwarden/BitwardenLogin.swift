import Foundation

/// The questions `bw login` asks on its terminal, recognized in what it printed. Bitwarden's command line tool asks
/// with the inquirer library: a line "? <question>" that is drawn again after every key, a list of choices for the
/// two-step method. What the person typed and everything else on that terminal is never kept beyond the
/// conversation and never logged.
public enum BitwardenPrompt: Equatable, Sendable {
    /// "Email address:" (aOS passes the address, so this shouldn't come)
    case email
    /// "Master password:" (aOS passes it through the environment, so this shouldn't come)
    case masterPassword
    /// "Two-step login method:" with the account's methods in Bitwarden's order, without "Cancel". Empty while the
    /// list isn't complete on the terminal yet.
    case twoStepMethod([String])
    /// "Two-step login code:"
    case twoStepCode
    /// "New device verification required. Enter OTP sent to login email:"
    case newDeviceCode
    /// "client_id:" or "client_secret:" (Bitwarden's personal API key)
    case apiKey(String)
    /// Anything else Bitwarden asks, as it asked it.
    case other(String)

    /// Identifies the question: each one is answered once per conversation.
    var key: String {
        switch self {
        case .email: return "email"
        case .masterPassword: return "password"
        case .twoStepMethod: return "method"
        case .twoStepCode: return "code"
        case .newDeviceCode: return "new-device"
        case .apiKey(let name): return "api:" + name
        case .other(let text): return "other:" + text
        }
    }

    /// Terminal output as plain lines: escape sequences that move the cursor or erase become line breaks (so the
    /// redrawn prompt lines stay apart), colors and every other escape sequence go away.
    static func plain(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[ABCDEFGHJKf]", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\u{1B}.?", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return s
    }

    /// The questions in plain terminal text, each once, in the order they first appeared.
    static func all(in text: String) -> [BitwardenPrompt] {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var found: [BitwardenPrompt] = []
        var seen = Set<String>()
        for index in lines.indices {
            guard let prompt = recognize(lines[index], following: lines[(index + 1)...]) else { continue }
            if seen.insert(prompt.key).inserted {
                found.append(prompt)
            } else if case .twoStepMethod(let choices) = prompt, !choices.isEmpty,
                      let at = found.firstIndex(where: { $0.key == prompt.key }), found[at] == .twoStepMethod([]) {
                found[at] = prompt  // the list became complete
            }
        }
        return found
    }

    private static func recognize(_ line: String, following: ArraySlice<String>) -> BitwardenPrompt? {
        let lower = line.lowercased()
        if lower.contains("two-step login method") { return .twoStepMethod(choices(following)) }
        if lower.contains("two-step login code") { return .twoStepCode }
        if lower.contains("new device verification") || lower.contains("otp sent to") { return .newDeviceCode }
        if lower.contains("master password:") { return .masterPassword }
        if lower.contains("email address:") { return .email }
        if lower.contains("client_id:") { return .apiKey("client_id") }
        if lower.contains("client_secret:") { return .apiKey("client_secret") }
        // inquirer's question mark, then the question up to its colon or question mark
        guard line.hasPrefix("? "), line.count > 3 else { return nil }
        let question = line.dropFirst(2)
        guard let end = question.firstIndex(where: { $0 == ":" || $0 == "?" }) else { return nil }
        let text = question[...end].trimmingCharacters(in: .whitespaces)
        return text.count > 1 ? .other(String(text.prefix(200))) : nil
    }

    /// The choices under the method question: lines up to Bitwarden's separator or "Cancel" (complete), or up to the
    /// next question (incomplete, empty).
    private static func choices(_ lines: ArraySlice<String>) -> [String] {
        var names: [String] = []
        for line in lines {
            if line.isEmpty { continue }
            if line.hasPrefix("?") { return [] }
            if line.allSatisfy({ $0 == "─" || $0 == "-" || $0 == "—" }) { return names }
            var name = line
            if let first = name.first, first == "❯" || first == ">" || first == "›" {
                name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if name == "Cancel" { return names }
            if name.hasPrefix("(") { continue }  // "(Use arrow keys)", "(Move up and down to reveal more choices)"
            if !names.contains(name) { names.append(name) }
        }
        return []
    }
}

/// One run of `bw login`, from the master password to the session key. Bitwarden's questions (two-step method and
/// code, the code for a new device) come as steps; the person answers in aOS's own fields and the answers are typed
/// into `bw`'s terminal, never put on a command line.
public final class BitwardenLoginConversation: @unchecked Sendable {
    public enum Step: Equatable, Sendable {
        /// Talking to Bitwarden.
        case working
        /// The account has several two-step methods: which one (Bitwarden's names, in its order).
        case chooseMethod([String])
        /// The code of the two-step method (authenticator app, the email Bitwarden just sent, the security key).
        case twoStepCode(method: String?)
        /// Bitwarden emailed a code because aOS signs in from a new device.
        case newDeviceCode
        /// Something else Bitwarden asks (its own words); `secret` hides what is typed.
        case question(String, secret: Bool)
    }

    /// How long a sign-in may take (an email code can take a few minutes to arrive).
    static let timeout: TimeInterval = 15 * 60

    let process: Subprocess.Interactive
    let email: String
    private let lock = NSLock()
    private var answered = Set<String>()
    private var shown: String?
    private var choices: [String] = []
    private var method: String?
    private var cancelled = false
    private var failure: BitwardenError?
    /// Called with every new step (on some thread; hop to the main actor yourself). Set it before `run()`.
    public var onStep: (@Sendable (Step) -> Void)?

    init(process: Subprocess.Interactive, email: String) {
        self.process = process
        self.email = email
    }

    /// Follows the conversation until `bw` ends; returns the session key.
    public func run() async throws -> String {
        var output = Data()
        for await chunk in process.terminal {
            output.append(chunk)
            if output.count > 1 << 20 { output.removeFirst(output.count - (1 << 20)) }
            advance(BitwardenPrompt.all(in: BitwardenPrompt.plain(String(decoding: output, as: UTF8.self))))
        }
        output.resetBytes(in: 0..<output.count)
        let result = await process.result()
        if let failure = lock.withLock({ cancelled ? BitwardenError.cancelled : self.failure }) { throw failure }
        if result.timedOut { throw BitwardenError.timeout }
        guard let reply = BitwardenCLI.reply(from: result.stdout) else {
            throw BitwardenError.unexpected("status \(result.status)")
        }
        guard reply.success else { throw BitwardenError(message: reply.message) }
        guard let key = reply.object?["raw"] as? String, BitwardenCLI.isSessionKey(key) else {
            throw BitwardenError.unexpected("no session key")
        }
        return key
    }

    /// Picks a two-step method (index into the step's list): arrow keys, then Return, as a person would.
    public func choose(_ index: Int) {
        let picked: String? = lock.withLock {
            guard shown == "method", index >= 0, index < choices.count else { return nil }
            answered.insert("method")
            shown = nil
            method = choices[index]
            return choices[index]
        }
        guard picked != nil else { return }
        onStep?(.working)
        let process = self.process
        Task.detached {
            for _ in 0..<index {
                process.send(Data("\u{1B}[B".utf8))
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            process.send(Data("\r".utf8))
        }
    }

    /// Answers the question that is shown (a code, or what Bitwarden asked). Line breaks and control characters are
    /// taken out, so one answer can't run into the next question.
    public func answer(_ text: String) {
        let clean = String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && !CharacterSet.newlines.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        let ok: Bool = lock.withLock {
            guard let key = shown, key != "method" else { return false }
            answered.insert(key)
            shown = nil
            return true
        }
        guard ok else { return }
        onStep?(.working)
        process.send(Data((clean + "\r").utf8))
    }

    /// Ends the sign-in; `run()` throws `.cancelled`.
    public func cancel() {
        lock.withLock { cancelled = true }
        process.terminate()
    }

    /// The first question not answered yet: shown once, or answered here when aOS knows the answer.
    private func advance(_ prompts: [BitwardenPrompt]) {
        let next: BitwardenPrompt? = lock.withLock {
            guard let prompt = prompts.first(where: { !answered.contains($0.key) }), shown != prompt.key else { return nil }
            if case .twoStepMethod(let list) = prompt {
                if list.isEmpty { return nil }  // the list isn't complete on the terminal yet
                choices = list
            }
            shown = prompt.key
            return prompt
        }
        guard let next else { return }
        switch next {
        case .email:
            answer(email)
        case .masterPassword:
            // aOS passes the master password through the environment and doesn't keep it to type it here.
            lock.withLock { failure = .failed("Bitwarden asked for the master password on its terminal.") }
            process.terminate()
        case .twoStepMethod(let list):
            if list.count == 1 { choose(0) } else { onStep?(.chooseMethod(list)) }
        case .twoStepCode:
            onStep?(.twoStepCode(method: lock.withLock { method }))
        case .newDeviceCode:
            onStep?(.newDeviceCode)
        case .apiKey(let name):
            onStep?(.question(name + ":", secret: name == "client_secret"))
        case .other(let text):
            let lower = text.lowercased()
            onStep?(.question(text, secret: lower.contains("password") || lower.contains("secret")))
        }
    }
}
