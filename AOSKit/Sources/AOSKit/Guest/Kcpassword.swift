import Foundation

/// /etc/kcpassword, the automatic login's copy of the account password: the password and a zero byte, padded with
/// zeros to a multiple of 12 bytes, XORed with macOS's fixed 11-byte key (an obfuscation, not encryption; the file is
/// root's, 0600).
enum Kcpassword {
    static let key: [UInt8] = [0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F]

    /// Whether `file` is the automatic login's copy of `password`: decoded with the key it starts with the password
    /// and a zero byte. What follows (padding; macOS may fill it differently) doesn't matter to the login window.
    static func matches(_ file: Data, password: String) -> Bool {
        let expected = Array(password.utf8) + [0]
        guard file.count >= expected.count, file.count % 12 == 0 else { return false }
        let decoded = file.enumerated().map { $0.element ^ key[$0.offset % key.count] }
        return Array(decoded.prefix(expected.count)) == expected
    }

    static func encode(_ password: String) -> Data {
        var bytes = Array(password.utf8) + [0]
        if bytes.count % 12 != 0 { bytes += [UInt8](repeating: 0, count: 12 - bytes.count % 12) }
        for i in bytes.indices { bytes[i] ^= key[i % key.count] }
        return Data(bytes)
    }
}
