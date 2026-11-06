import CryptoKit
import Foundation

/// OpenSSH text forms of public keys and their fingerprints, without depending on an SSH library.
enum SSHKeyFormat {
    static let p256KeyType = "ecdsa-sha2-nistp256"

    /// `ecdsa-sha2-nistp256 AAAA...` for a P-256 public key given in X9.63 form (`04 || X || Y`), as in
    /// `authorized_keys` (RFC 5656: string "ecdsa-sha2-nistp256", string "nistp256", string Q).
    static func openSSHP256(x963 point: Data) -> String {
        var blob = Data()
        appendString(Data(p256KeyType.utf8), to: &blob)
        appendString(Data("nistp256".utf8), to: &blob)
        appendString(point, to: &blob)
        return p256KeyType + " " + blob.base64EncodedString()
    }

    /// The binary key blob of an OpenSSH public key line (`<type> <base64> [comment]`).
    static func blob(ofOpenSSHKey line: String) -> Data? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        // The blob starts with the key type again; it must agree with the text.
        guard let type = readString(blob), type == Data(parts[0].utf8) else { return nil }
        return blob
    }

    /// The key type inside a blob (`ssh-ed25519`, `ecdsa-sha2-nistp256`, ...).
    static func keyType(ofBlob blob: Data) -> String? {
        readString(blob).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `SHA256:<base64 without padding>`, exactly as `ssh-keygen -l` prints it.
    static func fingerprint(blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    static func fingerprint(openSSHKey line: String) -> String? {
        blob(ofOpenSSHKey: line).map(fingerprint(blob:))
    }

    /// Accepts `SHA256:<base64>` with or without padding; returns the canonical form or nil if it isn't 32 bytes.
    static func normalizedFingerprint(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("SHA256:") else { return nil }
        let body = trimmed.dropFirst("SHA256:".count).replacingOccurrences(of: "=", with: "")
        guard let digest = base64DecodeUnpadded(body), digest.count == 32 else { return nil }
        return "SHA256:" + body
    }

    /// Fingerprints compared in constant time (they're public, but it costs nothing).
    static func fingerprintsEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: Base64 variants

    static func base64DecodeUnpadded(_ text: String) -> Data? {
        var s = text
        let remainder = s.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    /// base64url (RFC 4648 §5), padding optional.
    static func base64URLDecode(_ text: String) -> Data? {
        let unpadded = text.replacingOccurrences(of: "=", with: "")
        guard unpadded.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return base64DecodeUnpadded(unpadded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: SSH wire strings

    private static func appendString(_ value: Data, to data: inout Data) {
        var length = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    private static func readString(_ data: Data) -> Data? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0, data.count >= 4 + length else { return nil }
        let start = data.startIndex + 4
        return data.subdata(in: start..<(start + length))
    }
}
