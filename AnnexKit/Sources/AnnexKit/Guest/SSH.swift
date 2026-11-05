import Foundation

public struct SSHResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String
    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

public enum SSHError: LocalizedError {
    case failed(String, Int32, String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let what, let code, let err):
            let tail = err.split(separator: "\n").suffix(3).joined(separator: " | ")
            return "\(what) failed (exit \(code))\(tail.isEmpty ? "" : ": \(tail)")"
        case .timeout(let what): return "\(what) timed out"
        }
    }
}

/// Runs commands in the guest with the system's OpenSSH client. Host keys are pinned in our own
/// known_hosts (accepted on the very first connection, which happens on the VM's private NAT network).
public struct SSH: Sendable {
    public enum Auth: Sendable {
        /// Password of the guest account, handed to ssh through SSH_ASKPASS (never on a command line).
        case password(user: String, passwordFile: URL)
        case key(user: String, keyFile: URL)
    }

    public let host: String
    public let auth: Auth
    public let secrets: GuestSecrets

    public init(host: String, auth: Auth, secrets: GuestSecrets) {
        self.host = host
        self.auth = auth
        self.secrets = secrets
    }

    private var askpassScript: URL { secrets.paths.keys.appendingPathComponent("askpass.sh") }

    private func arguments(command: String) throws -> [String] {
        var args = [
            "-o", "UserKnownHostsFile=\(secrets.knownHosts.path)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "LogLevel=ERROR",
            "-F", "/dev/null",
        ]
        switch auth {
        case .password(let user, _):
            args += ["-o", "PubkeyAuthentication=no",
                     "-o", "PreferredAuthentications=password,keyboard-interactive",
                     "-o", "NumberOfPasswordPrompts=1",
                     "-l", user]
        case .key(let user, let key):
            args += ["-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-i", key.path, "-l", user]
        }
        args += [host, command]
        return args
    }

    private func environment() throws -> [String: String] {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"]
        if case .password(_, let file) = auth {
            // The script prints the password file; ssh calls it instead of asking on a terminal.
            let script = "#!/bin/sh\nexec /bin/cat \"\(file.path)\"\n"
            try Data(script.utf8).write(to: askpassScript, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpassScript.path)
            env["SSH_ASKPASS"] = askpassScript.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = "annex"
        }
        return env
    }

    /// Runs `command` in the guest, feeding `input` to its stdin. Throws on a non-zero exit unless
    /// `check` is false.
    @discardableResult
    public func run(_ command: String, input: Data? = nil, timeout: TimeInterval = 120,
                    check: Bool = true, what: String? = nil) async throws -> SSHResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try arguments(command: command)
        process.environment = try environment()
        let out = Pipe(), err = Pipe(), inp = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = inp
        try process.run()
        if let input { inp.fileHandleForWriting.write(input) }
        try? inp.fileHandleForWriting.close()

        let label = what ?? "ssh command"
        let result: SSHResult = try await withThrowingTaskGroup(of: SSHResult?.self) { group in
            group.addTask {
                async let o = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
                async let e = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
                let (stdout, stderr) = await (o, e)
                process.waitUntilExit()
                return SSHResult(status: process.terminationStatus, stdout: stdout,
                                 stderr: String(decoding: stderr, as: UTF8.self))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = try await group.next()!
            group.cancelAll()
            guard let first else {
                process.terminate()
                throw SSHError.timeout(label)
            }
            return first
        }
        if check && result.status != 0 { throw SSHError.failed(label, result.status, result.stderr) }
        return result
    }

    /// Waits until the guest accepts SSH connections (answers `true`).
    public func waitUntilReachable(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                try await run("true", timeout: 15, what: "SSH connection")
                return
            } catch { lastError = error }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw lastError ?? SSHError.timeout("SSH connection")
    }

    /// Creates an ed25519 key pair without passphrase (private 0600), unless it exists.
    public static func ensureKey(_ url: URL, comment: String) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", url.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SSHError.failed("ssh-keygen", p.terminationStatus, "") }
    }

    public static func publicKey(_ url: URL) throws -> String {
        try String(contentsOf: url.appendingPathExtension("pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
