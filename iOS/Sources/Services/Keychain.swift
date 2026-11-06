import Foundation
import LocalAuthentication
import Security

/// Generic password items in the iOS keychain: this device only, never synchronized, never in backups.
enum Keychain {
    enum Protection: Sendable {
        /// Readable after the first unlock since boot (keys and settings needed for reconnecting).
        case afterFirstUnlock
        /// Readable while the iPhone is unlocked.
        case whenUnlocked
        /// Needs a device passcode, and every read needs Face ID, Touch ID or the passcode.
        case userPresence
    }

    enum Failure: Error, Equatable {
        /// The person cancelled Face ID or the passcode prompt.
        case cancelled
        /// Face ID failed or isn't allowed (yet) for this read.
        case authenticationFailed
        /// The iPhone has no passcode; items that need one can't be stored.
        case noPasscode
        case unexpected(OSStatus)
    }

    static func set(_ data: Data, service: String, account: String, protection: Protection) throws {
        // Delete and add instead of updating: an update of an item behind user presence would ask for Face ID.
        try delete(service: service, account: account)
        var query = base(service: service, account: account)
        query[kSecValueData as String] = data
        switch protection {
        case .afterFirstUnlock:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlocked:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .userPresence:
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                               .userPresence, &error) else {
                throw Failure.unexpected(errSecParam)
            }
            query[kSecAttrAccessControl as String] = access
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status, protection: protection) }
    }

    /// The item's data, or nil if there is none. Items behind user presence use `context` when it was evaluated
    /// already (no second prompt); otherwise iOS asks with `prompt`.
    static func get(service: String, account: String, context: LAContext? = nil, prompt: String? = nil) throws -> Data? {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        } else if let prompt {
            // Without an evaluated context iOS asks itself; this says why.
            let asking = LAContext()
            asking.localizedReason = prompt
            query[kSecUseAuthenticationContext as String] = asking
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw failure(status, protection: .userPresence)
        }
    }

    static func delete(service: String, account: String) throws {
        let status = SecItemDelete(base(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unexpected(status) }
    }

    static func deleteAll(service: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecUseDataProtectionKeychain as String: true]
        SecItemDelete(query as CFDictionary)
    }

    /// The accounts stored under a service, without reading (or unlocking) their data.
    static func accounts(service: String) throws -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecUseDataProtectionKeychain as String: true,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw Failure.unexpected(status) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: Codable helpers

    static func setJSON<T: Encodable>(_ value: T, service: String, account: String, protection: Protection) throws {
        try set(JSONEncoder().encode(value), service: service, account: account, protection: protection)
    }

    static func getJSON<T: Decodable>(_ type: T.Type, service: String, account: String, context: LAContext? = nil,
                                      prompt: String? = nil) throws -> T? {
        guard let data = try get(service: service, account: account, context: context, prompt: prompt) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func base(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    private static func failure(_ status: OSStatus, protection: Protection) -> Failure {
        switch status {
        case errSecUserCanceled: return .cancelled
        case errSecAuthFailed, errSecInteractionNotAllowed:
            return protection == .userPresence && !hasPasscode ? .noPasscode : .authenticationFailed
        case errSecNotAvailable, errSecDecode:
            return protection == .userPresence && !hasPasscode ? .noPasscode : .unexpected(status)
        default: return .unexpected(status)
        }
    }

    /// Whether the iPhone has a passcode (items behind user presence need one).
    static var hasPasscode: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}
