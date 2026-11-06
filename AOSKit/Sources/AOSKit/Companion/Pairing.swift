import CryptoKit
import Darwin
import Foundation
import Network
import SystemConfiguration

/// The phones paired with this Mac: their SSH keys in ~/.ssh/authorized_keys, marked `aos-companion:<id>`.
public struct AuthorizedKeys: Sendable {
    public struct Device: Identifiable, Sendable, Equatable {
        public var id: String
        public var name: String
    }

    public let url: URL

    public init() {
        if let override = ProcessInfo.processInfo.environment["AOS_AUTHORIZED_KEYS"], !override.isEmpty {
            url = URL(fileURLWithPath: override)
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/authorized_keys")
        }
    }

    public init(url: URL) { self.url = url }

    static let marker = "aos-companion:"

    public func devices() -> [Device] {
        guard let data = try? read() else { return [] }
        return Self.lines(data).compactMap { raw in
            let line = String(decoding: raw, as: UTF8.self)
            guard let range = line.range(of: Self.marker) else { return nil }
            let rest = line[range.upperBound...]
            let id = rest.prefix { !$0.isWhitespace }
            let name = rest.dropFirst(id.count).trimmingCharacters(in: .whitespaces)
            return Device(id: String(id), name: name.isEmpty ? "iPhone" : name)
        }
    }

    /// Appends a phone's key (options keep it to a shell, commands and forwarded connections). The file is edited
    /// as bytes, line by line: other lines stay exactly as they are, whatever their encoding.
    public func add(key: String, id: String, name: String) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let safeName = name.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil
            || " -_'’.".unicodeScalars.contains($0) }.map(String.init).joined().prefix(60)
        let line = Data("no-agent-forwarding,no-X11-forwarding \(key) \(Self.marker)\(id) \(safeName)".utf8)
        // The same key again (pairing a second time): keep one line
        var lines = try read().map(Self.lines) ?? []
        lines.removeAll { Self.line($0, belongsTo: id) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.append(line)
        try write(lines)
    }

    public func remove(id: String) throws {
        guard let data = try read() else { return }
        var lines = Self.lines(data)
        lines.removeAll { Self.line($0, belongsTo: id) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        try write(lines)
    }

    /// The real file when authorized_keys is a link (dotfiles kept elsewhere): the link stays a link.
    private var target: URL { url.resolvingSymlinksInPath() }

    /// The file's bytes, nil when there is none. A file that exists but can't be read is an error: it must never
    /// be replaced by a file with only our line.
    private func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return try Data(contentsOf: target)
    }

    static func lines(_ data: Data) -> [Data] {
        data.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
    }

    static func line(_ line: Data, belongsTo id: String) -> Bool {
        line.range(of: Data("\(marker)\(id) ".utf8)) != nil || line.suffix(marker.utf8.count + id.utf8.count)
            == Data("\(marker)\(id)".utf8)
    }

    private func write(_ lines: [Data]) throws {
        var data = Data(lines.joined(separator: [0x0A]))
        if !data.isEmpty { data.append(0x0A) }
        let file = target
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".authorized_keys.aos-\(UUID().uuidString)")
        try data.write(to: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: file)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Facts about this Mac's SSH server (Remote Login) for pairing.
public enum MacSSH {
    /// Remote Login answers on port 22.
    public static func remoteLoginOn() -> Bool { TCPCheck.reachable(host: "127.0.0.1", port: 22, timeout: 2) }

    /// SHA256 fingerprint of the ed25519 host key, as `ssh-keygen -l` prints it.
    public static func hostKeyFingerprint() -> String? {
        guard let line = try? String(contentsOfFile: "/etc/ssh/ssh_host_ed25519_key.pub", encoding: .utf8) else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "ssh-ed25519", let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Names and addresses a phone can try, best first: the Bonjour name, then IPv4 addresses (Wi-Fi and Ethernet,
    /// then VPNs such as Tailscale). The workspace's own network (bridge) is left out.
    public static func addresses() -> [String] {
        var out: [String] = []
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? { out.append("\(local).local") }
        var lan: [String] = [], vpn: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            let flags = Int32(a.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = a.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: a.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if name.hasPrefix("en") { lan.append(ip) } else if name.hasPrefix("utun") { vpn.append(ip) }
        }
        return out + lan + vpn
    }

    /// Whether an address is in the network of a bridge interface (the workspace's network).
    public static func isOnVirtualMachineBridge(_ address: IPv4Address) -> Bool {
        let remote = address.rawValue.withUnsafeBytes { $0.load(as: UInt32.self) }
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard String(cString: a.pointee.ifa_name).hasPrefix("bridge"), let sa = a.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET), let mask = a.pointee.ifa_netmask else { continue }
            let local = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if local & bits == remote & bits { return true }
        }
        return false
    }

    public static func macName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }
}

/// Pairs one phone (Docs/COMPANION.md, "Pairing"): listens on a random port for 3 minutes, takes the phone's key when
/// its proof of the QR code's secret is right, and puts the key into authorized_keys.
@MainActor
public final class PairingSession {
    public enum State: Equatable {
        case starting, waiting, paired(String), failed(String), expired
    }

    public private(set) var state: State = .starting { didSet { onChange?() } }
    public private(set) var url: String?
    public private(set) var expires = Date().addingTimeInterval(180)
    public var onChange: (() -> Void)?

    private var listener: NWListener?
    private let code: Data
    private let keys: AuthorizedKeys
    private let sshPort: UInt16
    private let fixedFingerprint: String?
    private var failures = 0
    private let hosts: [String]?
    private let companion: String

    /// aos-companion in this app (the phone runs it over SSH), or where aOS is normally installed.
    public static var companionPath: String {
        let app = Bundle.main.bundleURL
        let inApp = app.appendingPathComponent("Contents/MacOS/aos-companion").path
        if app.pathExtension == "app", AppLocation.isStable(app), FileManager.default.isExecutableFile(atPath: inApp) {
            return inApp
        }
        return "/Applications/\(Brand.name).app/Contents/MacOS/aos-companion"
    }

    /// Tests pass another key file, SSH port and host key fingerprint (an sshd of their own), and may name the hosts
    /// and the companion program.
    public init(keys: AuthorizedKeys = AuthorizedKeys(), sshPort: UInt16 = 22, hostKeyFingerprint: String? = nil,
                hosts: [String]? = nil, companion: String? = nil) {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        code = Data(bytes)
        self.keys = keys
        self.sshPort = sshPort
        self.fixedFingerprint = hostKeyFingerprint
        self.hosts = hosts
        self.companion = companion ?? Self.companionPath
    }

    public func start() {
        guard TCPCheck.reachable(host: "127.0.0.1", port: sshPort, timeout: 2) else {
            state = .failed("Remote Login is off"); return
        }
        guard let fingerprint = fixedFingerprint ?? MacSSH.hostKeyFingerprint() else {
            state = .failed("no SSH host key"); return
        }
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            let l = try NWListener(using: params)
            l.service = NWListener.Service(name: MacSSH.macName(), type: "_aos-pair._tcp")
            l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
            l.stateUpdateHandler = { [weak self] s in
                Task { @MainActor in
                    guard let self else { return }
                    switch s {
                    case .ready:
                        guard let port = l.port?.rawValue else { return }
                        self.url = self.makeURL(port: port, fingerprint: fingerprint)
                        self.state = .waiting
                    case .failed(let e): self.state = .failed(e.localizedDescription)
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
            expires = Date().addingTimeInterval(180)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                guard let self, self.state == .waiting || self.state == .starting else { return }
                self.stop()
                self.state = .expired
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// HMAC-SHA256(code, "aos-pair-answer\n" + user + "\n" + companion): the phone checks that the answer comes
    /// from the Mac that shows the code and wasn't changed on its way (it names the program the phone runs).
    public nonisolated static func answerAuthentication(code: Data, user: String, companion: String) -> Data {
        let message = Data(("aos-pair-answer\n" + user + "\n" + companion).utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: code)))
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    func makeURL(port: UInt16, fingerprint: String) -> String {
        let codeText = code.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let items: [(String, String)] = [
            ("n", MacSSH.macName()),
            ("h", (hosts ?? MacSSH.addresses()).joined(separator: ",")),
            ("p", String(port)),
            ("s", String(sshPort)),
            ("u", NSUserName()),
            ("k", fingerprint),
            ("c", codeText),
        ]
        // Every value strictly encoded: only A-Z a-z 0-9 - . _ ~ stay as they are (the fingerprint's base64 has
        // + / = that must not change meaning).
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        return "aos-pair://v1?" + query
    }

    private func accept(_ connection: NWConnection) {
        guard case .waiting = state else { connection.cancel(); return }
        // Not from the workspace: it has no phone to pair, and must not use up the attempts.
        if case .hostPort(let host, _) = connection.endpoint, case .ipv4(let address) = host,
           MacSSH.isOnVirtualMachineBridge(address) {
            connection.cancel()
            return
        }
        connection.start(queue: .main)
        receiveLine(connection, buffer: Data())
        // Whatever happens, the connection doesn't stay longer than 15 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { connection.cancel() }
    }

    private func receiveLine(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let nl = buffer.firstIndex(of: 0x0A) {
                    self.handle(Data(buffer[..<nl]), connection)
                } else if buffer.count > 16384 || complete || error != nil {
                    connection.cancel()
                } else {
                    self.receiveLine(connection, buffer: buffer)
                }
            }
        }
    }

    /// Checks a pairing request; see `PairingRequest.verify`.
    private func handle(_ line: Data, _ connection: NWConnection) {
        /// Sends the answer; `then` runs once it is out (only then may the pairing end).
        func respond(_ o: [String: Any], then: @escaping @MainActor () -> Void = {}) {
            let data = ((try? JSONSerialization.data(withJSONObject: o)) ?? Data()) + Data([0x0A])
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
                Task { @MainActor in then() }
            })
        }
        switch PairingRequest.verify(line, code: code) {
        case .failure(let reason):
            failures += 1
            respond(["ok": false, "error": reason])
            if failures >= 5 { stop(); state = .failed("too many wrong attempts") }
        case .success(let request):
            do {
                try keys.add(key: request.key, id: request.id, name: request.device)
                let user = NSUserName()
                let mac = Self.answerAuthentication(code: code, user: user, companion: companion).base64EncodedString()
                respond(["ok": true, "user": user, "companion": companion, "mac": mac]) { [weak self] in
                    self?.stop()
                    self?.state = .paired(request.device)
                }
            } catch {
                respond(["ok": false, "error": "could not save the key"])
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// A phone's pairing request: `{"v":1,"device":"...","key":"ecdsa-sha2-nistp256 AAAA...","proof":"<base64>"}` with
/// proof = HMAC-SHA256(code, key + "\n" + device).
/// The key type at the start of an SSH public key blob (a 4-byte big-endian length, then the name).
func blobType(_ blob: Data) -> String? {
    guard blob.count >= 4 else { return nil }
    let bytes = [UInt8](blob)
    let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
    guard length > 0, length < 64, bytes.count >= 4 + length else { return nil }
    return String(bytes: bytes[4..<(4 + length)], encoding: .ascii)
}

public struct PairingRequest: Sendable {
    public var device: String
    public var key: String
    /// First 12 hex characters of the SHA-256 of the key blob.
    public var id: String

    public enum Result { case success(PairingRequest), failure(String) }

    public static func verify(_ line: Data, code: Data) -> Result {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (o["v"] as? Int) == 1, let device = o["device"] as? String, let key = o["key"] as? String,
              let proofText = o["proof"] as? String, let proof = Data(base64Encoded: proofText) else {
            return .failure("bad request")
        }
        let message = Data((key + "\n" + device).utf8)
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: code)) else {
            return .failure("wrong code")
        }
        // Exactly "<type> <base64>", and the blob says the same type: nothing else can reach authorized_keys
        let parts = key.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, ["ecdsa-sha2-nistp256", "ssh-ed25519"].contains(String(parts[0])),
              let blob = Data(base64Encoded: String(parts[1])), blob.count >= 32, blob.count < 1024,
              blobType(blob) == String(parts[0]) else {
            return .failure("unsupported key")
        }
        let id = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined().prefix(12)
        let name = device.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(PairingRequest(device: name.isEmpty ? "iPhone" : String(name.prefix(60)), key: key, id: String(id)))
    }
}
