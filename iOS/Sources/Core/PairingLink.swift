import CryptoKit
import Foundation

/// The pairing code that aOS on the Mac shows as a QR code (Docs/COMPANION.md, "Pairing"):
///
///     aos-pair://v1?n=<Mac name>&h=<host1>,<host2>&p=<pairing port>&s=22&u=<user>&k=<host key fingerprint>&c=<code>
///
/// All values are percent-encoded. `c` is a secret: it only lives in the QR code and proves to the Mac that this iPhone
/// saw the code; it is never sent.
struct PairingLink: Equatable, Sendable {
    var macName: String
    /// Names and addresses to try in order: `<name>.local`, IPv4 addresses, Tailscale name.
    var hosts: [String]
    var pairingPort: UInt16
    var sshPort: UInt16
    var user: String
    /// `SHA256:...` of the Mac's ed25519 SSH host key (OpenSSH form, no padding).
    var hostKeyFingerprint: String
    /// The 16 random bytes of `c`.
    var code: Data

    static let scheme = "aos-pair"

    enum ParseError: Error, Equatable {
        case notAPairingLink
        case newerVersion
        case missing(String)
        case invalid(String)
    }

    init(macName: String, hosts: [String], pairingPort: UInt16, sshPort: UInt16 = 22, user: String,
         hostKeyFingerprint: String, code: Data) {
        self.macName = macName
        self.hosts = hosts
        self.pairingPort = pairingPort
        self.sshPort = sshPort
        self.user = user
        self.hostKeyFingerprint = hostKeyFingerprint
        self.code = code
    }

    /// Parses a pasted or scanned link. Surrounding white space is ignored.
    init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A link typed or pasted by hand may contain plain spaces (in the Mac name).
        guard let components = URLComponents(string: trimmed)
                ?? URLComponents(string: trimmed.replacingOccurrences(of: " ", with: "%20")),
              components.scheme?.lowercased() == Self.scheme else { throw ParseError.notAPairingLink }
        // aos-pair://v1?... puts the version in the host position.
        guard let version = components.host?.lowercased(), !version.isEmpty else { throw ParseError.notAPairingLink }
        guard version == "v1" else {
            if version.hasPrefix("v"), Int(version.dropFirst()) != nil { throw ParseError.newerVersion }
            throw ParseError.notAPairingLink
        }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            values[item.name] = item.value ?? ""
        }
        func required(_ name: String) throws -> String {
            guard let value = values[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
                throw ParseError.missing(name)
            }
            return value
        }

        let hosts = try required("h").split(separator: ",").map(Self.normalizedHost).filter { !$0.isEmpty }
        var seen = Set<String>()
        self.hosts = hosts.filter { seen.insert($0.lowercased()).inserted }
        guard !self.hosts.isEmpty else { throw ParseError.missing("h") }
        guard self.hosts.allSatisfy(Self.isPlausibleHost) else { throw ParseError.invalid("h") }

        guard let pairingPort = UInt16(try required("p")), pairingPort > 0 else { throw ParseError.invalid("p") }
        self.pairingPort = pairingPort
        if let s = values["s"], !s.isEmpty {
            guard let sshPort = UInt16(s), sshPort > 0 else { throw ParseError.invalid("s") }
            self.sshPort = sshPort
        } else {
            sshPort = 22
        }

        let user = try required("u")
        guard user.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) })
        else { throw ParseError.invalid("u") }
        self.user = user

        guard let fingerprint = SSHKeyFormat.normalizedFingerprint(try required("k")) else { throw ParseError.invalid("k") }
        hostKeyFingerprint = fingerprint

        guard let code = SSHKeyFormat.base64URLDecode(try required("c")), code.count == 16 else {
            throw ParseError.invalid("c")
        }
        self.code = code

        let name = (values["n"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        macName = name.isEmpty ? self.hosts[0] : String(name.prefix(80))
    }

    /// The link as aOS on the Mac writes it (used by the tests and the demo).
    var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "v1"
        // Percent-encode everything that isn't unreserved, so "+" and "/" in base64 values survive any decoder.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        c.percentEncodedQuery = [
            "n=" + enc(macName),
            "h=" + hosts.map(enc).joined(separator: ","),
            "p=\(pairingPort)",
            "s=\(sshPort)",
            "u=" + enc(user),
            "k=" + enc(hostKeyFingerprint),
            "c=" + enc(SSHKeyFormat.base64URLEncode(code)),
        ].joined(separator: "&")
        return c.url!
    }

    private static func normalizedHost(_ raw: Substring) -> String {
        var host = raw.trimmingCharacters(in: .whitespaces)
        // "[fe80::1]" -> "fe80::1"
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix("."), host.count > 1 { host.removeLast() }
        return host
    }

    private static func isPlausibleHost(_ host: String) -> Bool {
        guard host.count <= 253 else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "/?#@\\\"'<>"))
        return host.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }
}

/// The one JSON line the iPhone sends to the Mac's pairing listener, and the proof in it.
struct PairingRequest: Codable, Equatable, Sendable {
    var v: Int = 1
    var device: String
    /// The device's public key exactly as it goes into `authorized_keys`: `ecdsa-sha2-nistp256 AAAA...`
    var key: String
    var proof: String

    init(device: String, key: String, code: Data) {
        self.device = device
        self.key = key
        self.proof = Self.proof(code: code, key: key, device: device)
    }

    /// `base64(HMAC-SHA256(c, key + "\n" + device))`, with `c` as its raw 16 bytes, the message as UTF-8 and the result
    /// in standard base64 with padding.
    static func proof(code: Data, key: String, device: String) -> String {
        let message = Data((key + "\n" + device).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: code))
        return Data(mac).base64EncodedString()
    }

    /// The request as one line, terminated by "\n".
    func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    /// A device name the Mac can put into `authorized_keys` as a comment: one line, printable, at most 64 characters.
    static func sanitizedDeviceName(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : Character(scalar)
        }
        let collapsed = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limited = String(collapsed.prefix(64)).trimmingCharacters(in: .whitespaces)
        return limited.isEmpty ? "iPhone" : limited
    }
}

/// The Mac's answer: `{"ok":true,"user":"<user>","companion":"<path>","mac":"<base64>"}` or
/// `{"ok":false,"error":"..."}`. `mac` is HMAC-SHA256(code, "aos-pair-answer\n" + user + "\n" + companion): only
/// the Mac that shows the code can write it, so nobody on the network can change the answer on its way.
struct PairingResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var user: String?
    var companion: String?
    var error: String?
    var mac: String?

    static func authentication(code: Data, user: String, companion: String) -> Data {
        let message = Data(("aos-pair-answer\n" + user + "\n" + companion).utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: code)))
    }

    /// The answer came from the Mac with this code, and names a plausible user and companion program.
    func isAuthentic(code: Data) -> Bool {
        guard ok, let user, let companion, let mac, let given = Data(base64Encoded: mac) else { return false }
        let expected = Self.authentication(code: code, user: user, companion: companion)
        guard given.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(given, expected) { difference |= a ^ b }
        return difference == 0 && Self.isPlausible(user: user) && Self.isPlausible(companion: companion)
    }

    static func isPlausible(user: String) -> Bool {
        !user.isEmpty && user.count <= 64 && user.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
    }

    static func isPlausible(companion: String) -> Bool {
        companion.hasPrefix("/") && companion.hasSuffix("/aos-companion") && companion.count < 1024
            && !companion.unicodeScalars.contains { $0.properties.generalCategory == .control }
            && !companion.contains("/../")
    }
}
