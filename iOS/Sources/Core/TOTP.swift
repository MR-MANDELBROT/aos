import CryptoKit
import Foundation

/// Time-based one-time passwords (RFC 6238 on top of HOTP, RFC 4226).
///
/// Accepts what password managers store: `otpauth://totp/Label?secret=...&algorithm=SHA256&digits=8&period=60`,
/// a bare base32 secret (spaces, dashes and lower case allowed), and Bitwarden's `steam://<secret>` for Steam Guard.
struct TOTP: Equatable, Sendable {
    enum Algorithm: String, Sendable, CaseIterable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    var secret: Data
    var algorithm: Algorithm = .sha1
    var digits: Int = 6
    var period: Int = 30
    var issuer: String?
    var account: String?
    /// Steam Guard: five characters from Steam's alphabet instead of digits.
    var isSteam = false

    enum ParseError: Error, Equatable { case empty, invalidSecret, unsupported(String), invalidParameter(String) }

    init(secret: Data, algorithm: Algorithm = .sha1, digits: Int = 6, period: Int = 30) {
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
    }

    init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        if trimmed.lowercased().hasPrefix("steam://") {
            guard let secret = Base32.decode(String(trimmed.dropFirst("steam://".count))), !secret.isEmpty else {
                throw ParseError.invalidSecret
            }
            self.init(secret: secret, digits: 5)
            isSteam = true
            return
        }

        guard trimmed.lowercased().hasPrefix("otpauth://") else {
            guard let secret = Base32.decode(trimmed), !secret.isEmpty else { throw ParseError.invalidSecret }
            self.init(secret: secret)
            return
        }

        guard let components = URLComponents(string: trimmed) else { throw ParseError.invalidSecret }
        guard components.host?.lowercased() == "totp" else { throw ParseError.unsupported(components.host ?? "") }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name.lowercased()] = item.value ?? "" }
        guard let secret = query["secret"].flatMap(Base32.decode), !secret.isEmpty else { throw ParseError.invalidSecret }
        self.init(secret: secret)

        if let a = query["algorithm"], !a.isEmpty {
            guard let algorithm = Algorithm(rawValue: a.uppercased().replacingOccurrences(of: "-", with: "")) else {
                throw ParseError.invalidParameter("algorithm")
            }
            self.algorithm = algorithm
        }
        if let d = query["digits"], !d.isEmpty {
            guard let digits = Int(d), (6...10).contains(digits) else { throw ParseError.invalidParameter("digits") }
            self.digits = digits
        }
        if let p = query["period"], !p.isEmpty {
            guard let period = Int(p), period > 0, period <= 3600 else { throw ParseError.invalidParameter("period") }
            self.period = period
        }

        // Label: "Issuer:account" or "account" (percent-decoded by URLComponents.path)
        let label = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        if let colon = label.firstIndex(of: ":") {
            issuer = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
            account = String(label[label.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else if !label.isEmpty {
            account = label
        }
        if let i = query["issuer"], !i.isEmpty { issuer = i }
    }

    /// HOTP value for a counter.
    func code(counter: UInt64) -> String {
        var big = counter.bigEndian
        let message = withUnsafeBytes(of: &big) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        // Dynamic truncation (RFC 4226 §5.3)
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let binary = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])

        if isSteam {
            let alphabet = Array("23456789BCDFGHJKMNPQRTVWXY")
            var value = Int(binary)
            var out = ""
            for _ in 0..<5 {
                out.append(alphabet[value % alphabet.count])
                value /= alphabet.count
            }
            return out
        }
        var modulo: UInt64 = 1
        for _ in 0..<digits { modulo *= 10 }
        let value = UInt64(binary) % modulo
        let text = String(value)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    func counter(at date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970) / Double(period))
    }

    func code(at date: Date = Date()) -> String { code(counter: counter(at: date)) }

    /// Seconds until the code changes.
    func secondsRemaining(at date: Date = Date()) -> Int {
        let elapsed = Int(max(0, date.timeIntervalSince1970)) % period
        return period - elapsed
    }
}

/// Base32 (RFC 4648) as used for TOTP secrets: case-insensitive, padding, spaces and dashes ignored.
enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func decode(_ text: String) -> Data? {
        var lookup = [Character: UInt8]()
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt8(i) }
        let cleaned = text.uppercased().filter { $0 != " " && $0 != "-" && $0 != "=" && $0 != "\t" && $0 != "\n" }
        guard !cleaned.isEmpty else { return nil }
        var buffer: UInt32 = 0, bits = 0
        var out = Data()
        for c in cleaned {
            guard let v = lookup[c] else { return nil }
            buffer = (buffer << 5) | UInt32(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xff))
            }
        }
        return out
    }

    static func encode(_ data: Data) -> String {
        var out = ""
        var buffer: UInt32 = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return out
    }
}
