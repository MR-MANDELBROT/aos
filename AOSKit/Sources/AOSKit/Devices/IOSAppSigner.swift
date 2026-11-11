import CryptoKit
import Foundation
import Security

/// A development provisioning profile of the person's (Xcode keeps them in its folders).
public struct ProvisioningProfile: Sendable {
    public var url: URL
    public var name: String
    public var uuid: String
    public var teamID: String
    /// "TEAM.dev.example.*" or "TEAM.dev.example.app".
    public var applicationIdentifier: String
    public var expiration: Date
    public var devices: [String]
    public var allDevices: Bool
    public var platforms: [String]
    public var getTaskAllow: Bool
    public var hasKeychainGroups: Bool
    /// SHA-1 fingerprints (uppercase hex) of the signing certificates it allows.
    public var certificateFingerprints: [String]

    /// The bundle id this profile signs: exact, or under its wildcard ("TEAM.*", "TEAM.dev.example.*").
    public func covers(bundleID: String) -> Bool {
        let prefix = teamID + "."
        guard applicationIdentifier.hasPrefix(prefix) else { return false }
        let pattern = String(applicationIdentifier.dropFirst(prefix.count))
        if pattern == "*" { return true }
        if pattern.hasSuffix(".*") { return bundleID.hasPrefix(String(pattern.dropLast(1))) }
        return pattern == bundleID
    }

    public func covers(device udid: String) -> Bool {
        allDevices || devices.contains { $0.caseInsensitiveCompare(udid) == .orderedSame }
    }

    public var isWildcard: Bool { applicationIdentifier.hasSuffix("*") }

    /// Reads a .mobileprovision (a CMS-signed property list).
    public static func read(_ url: URL) -> ProvisioningProfile? {
        guard let data = try? Data(contentsOf: url), let plist = decodeCMS(data),
              let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let entitlements = dict["Entitlements"] as? [String: Any],
              let appID = entitlements["application-identifier"] as? String,
              let team = (dict["TeamIdentifier"] as? [String])?.first,
              let expiration = dict["ExpirationDate"] as? Date else { return nil }
        let certificates = (dict["DeveloperCertificates"] as? [Data]) ?? []
        return ProvisioningProfile(
            url: url, name: dict["Name"] as? String ?? url.lastPathComponent, uuid: dict["UUID"] as? String ?? "",
            teamID: team, applicationIdentifier: appID, expiration: expiration,
            devices: dict["ProvisionedDevices"] as? [String] ?? [],
            allDevices: dict["ProvisionsAllDevices"] as? Bool ?? false,
            platforms: dict["Platform"] as? [String] ?? [],
            getTaskAllow: entitlements["get-task-allow"] as? Bool ?? false,
            hasKeychainGroups: entitlements["keychain-access-groups"] != nil,
            certificateFingerprints: certificates.map { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() })
    }

    static func decodeCMS(_ data: Data) -> Data? {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let added = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, data.count) }
        guard added == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        return content as Data
    }

    /// Where Xcode keeps profiles (the newer folder first).
    public static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles"),
                home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles")]
    }

    public static func all(in folders: [URL] = folders) -> [ProvisioningProfile] {
        var seen = Set<String>()
        var result: [ProvisioningProfile] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "mobileprovision" {
                guard let profile = read(file), seen.insert(profile.uuid).inserted else { continue }
                result.append(profile)
            }
        }
        return result
    }
}

/// A code signing identity in the person's keychain.
public struct SigningIdentity: Sendable, Equatable {
    public var fingerprint: String
    public var name: String

    /// `security find-identity -v -p codesigning` lines: `  1) <SHA-1> "<name>"`.
    public static func parse(_ text: String) -> [SigningIdentity] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
            guard parts.count == 3, parts[0].hasSuffix(")"), parts[1].count == 40,
                  parts[2].hasPrefix("\""), parts[2].hasSuffix("\"") else { return nil }
            return SigningIdentity(fingerprint: String(parts[1]).uppercased(), name: String(parts[2].dropFirst().dropLast()))
        }
    }

    public static func all() async -> [SigningIdentity] {
        guard let result = try? await Subprocess.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"],
                                                     timeout: 30) else { return [] }
        return parse(String(decoding: result.stdout, as: UTF8.self))
    }
}

/// An iPhone app ready to sign: what its Info.plist says.
public struct IOSAppBundle: Sendable {
    public var url: URL
    public var bundleID: String
    public var name: String
    public var version: String?

    public static func read(_ url: URL) throws -> IOSAppBundle {
        let info = url.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: info),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = dict["CFBundleIdentifier"] as? String, !id.isEmpty else {
            throw IOSAppSigner.SignError.notAnApp(url.lastPathComponent)
        }
        let platforms = dict["CFBundleSupportedPlatforms"] as? [String] ?? []
        if platforms.contains("iPhoneSimulator") { throw IOSAppSigner.SignError.simulatorBuild }
        let name = (dict["CFBundleDisplayName"] as? String) ?? (dict["CFBundleName"] as? String) ?? id
        let short = dict["CFBundleShortVersionString"] as? String
        let build = dict["CFBundleVersion"] as? String
        let version = [short, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        return IOSAppBundle(url: url, bundleID: id, name: name, version: version.isEmpty ? nil : version)
    }
}

/// Signs iPhone apps with the person's development identity and a profile that covers the app and the iPhone, the
/// way Xcode does for a device build (aOS never asks Xcode to manage signing: that signs the person out of Xcode).
public struct IOSAppSigner: Sendable {
    public enum SignError: LocalizedError, Equatable {
        case notAnApp(String)
        case simulatorBuild
        /// `covered`: the bundle id patterns the person's wildcard profiles cover on this iPhone ("dev.example.*").
        case noProfile(bundleID: String, udid: String, covered: [String] = [])
        case noIdentity(profile: String)
        case codesign(String, String)

        public var errorDescription: String? {
            switch self {
            case .notAnApp(let name):
                return "\(name) is not an iPhone app (no Info.plist with a bundle id)."
            case .simulatorBuild:
                return "This is a build for the iOS Simulator. Build for a device (generic/platform=iOS)."
            case .noProfile(let id, let udid, let covered):
                if !covered.isEmpty {
                    return "No development provisioning profile covers \(id) on this iPhone. Use a bundle id under "
                        + covered.joined(separator: " or ") + " (the person's wildcard profile covers those), then build again."
                }
                return "No development provisioning profile in Xcode covers \(id) and this iPhone (\(udid)). "
                    + "A wildcard profile of the team covers every app under its prefix: \(Brand.name) > Settings > Apps > "
                    + "Set Up Step by Step."
            case .noIdentity(let profile):
                return "The signing certificate of the profile \(profile) isn't in the keychain."
            case .codesign(let path, let output):
                return "codesign failed for \(path): \(output)"
            }
        }
    }

    public var profiles: [ProvisioningProfile]
    public var identities: [SigningIdentity]
    public var now = Date()

    public init(profiles: [ProvisioningProfile], identities: [SigningIdentity]) {
        self.profiles = profiles
        self.identities = identities
    }

    /// The person's profiles and identities as they are now.
    public static func current() async -> IOSAppSigner {
        IOSAppSigner(profiles: ProvisioningProfile.all(), identities: await SigningIdentity.all())
    }

    /// The best profile for the app on the device, with an identity it allows: an exact one before a wildcard, then
    /// the one that runs longest.
    public func choose(bundleID: String, udid: String) throws -> (ProvisioningProfile, SigningIdentity) {
        let usable = profiles.filter {
            $0.expiration > now && $0.covers(bundleID: bundleID) && $0.covers(device: udid)
                && ($0.platforms.isEmpty || $0.platforms.contains("iOS"))
        }
        guard !usable.isEmpty else { throw SignError.noProfile(bundleID: bundleID, udid: udid, covered: coveredPatterns(udid: udid)) }
        let ranked = usable.sorted {
            if $0.isWildcard != $1.isWildcard { return !$0.isWildcard }
            return $0.expiration > $1.expiration
        }
        for profile in ranked {
            if let identity = identities.first(where: { profile.certificateFingerprints.contains($0.fingerprint) }) {
                return (profile, identity)
            }
        }
        throw SignError.noIdentity(profile: ranked[0].name)
    }

    /// The bundle id patterns ("dev.example.*") of the valid wildcard profiles that cover the iPhone and have their
    /// certificate in the keychain: every app under one of them can be signed for it.
    public func coveredPatterns(udid: String) -> [String] {
        let patterns = profiles.filter { profile in
            profile.isWildcard && profile.expiration > now && profile.covers(device: udid)
                && (profile.platforms.isEmpty || profile.platforms.contains("iOS"))
                && identities.contains { profile.certificateFingerprints.contains($0.fingerprint) }
        }.map { String($0.applicationIdentifier.dropFirst($0.teamID.count + 1)) }
        return Array(Set(patterns)).sorted()
    }

    /// The entitlements a development build of `bundleID` gets under `profile`.
    public static func entitlements(bundleID: String, profile: ProvisioningProfile) -> [String: Any] {
        var e: [String: Any] = [
            "application-identifier": "\(profile.teamID).\(bundleID)",
            "com.apple.developer.team-identifier": profile.teamID,
            "get-task-allow": profile.getTaskAllow,
        ]
        if profile.hasKeychainGroups { e["keychain-access-groups"] = ["\(profile.teamID).\(bundleID)"] }
        return e
    }

    /// Signs the app at `app` in place (a copy aOS made): frameworks and libraries, then extensions, then the app.
    /// Returns what was signed with what.
    @discardableResult
    public func sign(app: URL, udid: String, workFolder: URL) async throws -> String {
        let bundle = try IOSAppBundle.read(app)
        let (profile, identity) = try choose(bundleID: bundle.bundleID, udid: udid)
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        // Inner code first, deepest first: nested bundles must be sealed before the bundle that contains them.
        let nested = Self.nestedCode(in: app).sorted { $0.pathComponents.count > $1.pathComponents.count }
        for item in nested {
            if item.pathExtension == "appex" {
                let ext = try IOSAppBundle.read(item)
                let (extProfile, _) = (try? choose(bundleID: ext.bundleID, udid: udid)) ?? (profile, identity)
                try? FileManager.default.removeItem(at: item.appendingPathComponent("embedded.mobileprovision"))
                try FileManager.default.copyItem(at: extProfile.url, to: item.appendingPathComponent("embedded.mobileprovision"))
                try await codesign(item, identity: identity,
                                   entitlements: Self.entitlements(bundleID: ext.bundleID, profile: extProfile),
                                   work: workFolder)
            } else {
                try await codesign(item, identity: identity, entitlements: nil, work: workFolder)
            }
        }
        try? FileManager.default.removeItem(at: app.appendingPathComponent("embedded.mobileprovision"))
        try FileManager.default.copyItem(at: profile.url, to: app.appendingPathComponent("embedded.mobileprovision"))
        try await codesign(app, identity: identity, entitlements: Self.entitlements(bundleID: bundle.bundleID, profile: profile),
                           work: workFolder)
        return "\(identity.name), profile \(profile.name)"
    }

    /// Frameworks, libraries and extensions inside an app (not the app itself).
    static func nestedCode(in app: URL) -> [URL] {
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: keys) else { return [] }
        for case let url as URL in walker {
            let ext = url.pathExtension
            if ["framework", "appex", "xpc"].contains(ext) || (ext == "dylib" && !(url.path.contains(".framework/"))) {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                found.append(url)
            }
        }
        return found
    }

    private func codesign(_ item: URL, identity: SigningIdentity, entitlements: [String: Any]?, work: URL) async throws {
        var args = ["--force", "--sign", identity.fingerprint, "--timestamp=none", "--generate-entitlement-der"]
        if let entitlements {
            let file = work.appendingPathComponent("entitlements-\(UUID().uuidString).plist")
            let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
            try data.write(to: file)
            args += ["--entitlements", file.path]
        }
        let result = try await Subprocess.run("/usr/bin/codesign", args + [item.path], timeout: 300)
        guard result.status == 0 else {
            let output = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SignError.codesign(item.lastPathComponent, output)
        }
    }
}
