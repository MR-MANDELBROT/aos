import CommonCrypto
import Foundation
import Security

/// Authentication schemes of macOS screen sharing.
enum RFBAuth {
    /// Apple's RSA scheme (security type 33): user name and password, each 64 bytes (UTF-8, NUL, random padding),
    /// encrypted with a random AES-128 key in ECB mode; the AES key encrypted with the server's RSA key (PKCS#1 v1.5).
    static func appleRSA(stream: RFBStream, username: String, password: String) async throws {
        // Ask for the host key
        var request = Data([0x00, 0x00, 0x00, 0x0a, 0x01, 0x00])
        request.append(contentsOf: Array("RSA1".utf8))
        request.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        try await stream.write(request)
        _ = try await stream.read(4)               // packet length
        _ = try await stream.read(2)               // packet version
        let keyLength = Int(try await stream.u32())
        guard keyLength > 0 && keyLength < 8192 else { throw RFBError.protocolError("host key length \(keyLength)") }
        let der = try await stream.read(keyLength)
        _ = try await stream.read(1)               // unknown

        let hostKey = try rsaPublicKey(der: der)
        var aesKey = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &aesKey) == errSecSuccess else {
            throw RFBError.authFailed("no random bytes")
        }
        let credentials = pack(username) + pack(password)
        let encryptedCredentials = try aesECB(key: aesKey, data: credentials)
        var error: Unmanaged<CFError>?
        guard let encryptedKey = SecKeyCreateEncryptedData(hostKey, .rsaEncryptionPKCS1, Data(aesKey) as CFData,
                                                           &error) as Data? else {
            throw RFBError.authFailed("RSA: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        var message = Data([0x00, 0x00, 0x01, 0x8a, 0x01, 0x00])
        message.append(contentsOf: Array("RSA1".utf8))
        message.append(contentsOf: [0x00, 0x01])
        message.append(encryptedCredentials)
        message.append(contentsOf: [0x00, 0x01])
        message.append(encryptedKey)
        try await stream.write(message)
        _ = try await stream.read(4)               // unknown
    }

    /// Classic VNC password authentication (security type 2): DES with the bit-reversed password as key.
    static func vncPassword(stream: RFBStream, password: String) async throws {
        let challenge = try await stream.read(16)
        var key = Array(password.utf8.prefix(8))
        while key.count < 8 { key.append(0) }
        key = key.map { b in
            var r: UInt8 = 0
            for i in 0..<8 where b & (1 << i) != 0 { r |= 1 << (7 - i) }
            return r
        }
        try await stream.write(try crypt(algorithm: CCAlgorithm(kCCAlgorithmDES), key: key, data: challenge))
    }

    static func pack(_ text: String) -> Data {
        var data = Data(text.utf8) + Data([0])
        if data.count < 64 {
            var pad = [UInt8](repeating: 0, count: 64 - data.count)
            _ = SecRandomCopyBytes(kSecRandomDefault, pad.count, &pad)
            data.append(contentsOf: pad)
        }
        return data.prefix(64)
    }

    static func aesECB(key: [UInt8], data: Data) throws -> Data {
        try crypt(algorithm: CCAlgorithm(kCCAlgorithmAES128), key: key, data: data)
    }

    private static func crypt(algorithm: CCAlgorithm, key: [UInt8], data: Data) throws -> Data {
        var out = Data(count: data.count + 32)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                CCCrypt(CCOperation(kCCEncrypt), algorithm, CCOptions(kCCOptionECBMode), key, key.count, nil,
                        i.baseAddress, data.count, o.baseAddress, outCount, &moved)
            }
        }
        guard status == kCCSuccess else { throw RFBError.authFailed("cipher \(status)") }
        return out.prefix(moved)
    }

    /// Accepts an RSA public key as X.509 SubjectPublicKeyInfo or bare PKCS#1.
    static func rsaPublicKey(der: Data) throws -> SecKey {
        let pkcs1 = (try? spkiToPKCS1(der)) ?? der
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            throw RFBError.authFailed("host key: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return key
    }

    /// SEQUENCE { SEQUENCE { algorithm }, BIT STRING { 0x00, RSAPublicKey } } -> RSAPublicKey
    static func spkiToPKCS1(_ der: Data) throws -> Data {
        let bytes = [UInt8](der)
        var i = 0
        func length() throws -> Int {
            guard i < bytes.count else { throw RFBError.protocolError("DER") }
            let first = Int(bytes[i]); i += 1
            if first < 0x80 { return first }
            let n = first & 0x7f
            guard n <= 4, i + n <= bytes.count else { throw RFBError.protocolError("DER") }
            var v = 0
            for _ in 0..<n { v = v << 8 | Int(bytes[i]); i += 1 }
            return v
        }
        func expect(_ tag: UInt8) throws {
            guard i < bytes.count, bytes[i] == tag else { throw RFBError.protocolError("DER") }
            i += 1
        }
        try expect(0x30); _ = try length()
        try expect(0x30); let algLen = try length(); i += algLen
        try expect(0x03); let bitLen = try length()
        guard i < bytes.count, bytes[i] == 0, i + bitLen <= bytes.count else { throw RFBError.protocolError("DER") }
        return Data(bytes[(i + 1)..<(i + bitLen)])
    }
}
