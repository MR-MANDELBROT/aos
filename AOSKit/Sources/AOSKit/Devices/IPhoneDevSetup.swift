import Foundation

/// What the guided setup of Settings > Apps checks on the Mac (Docs/DESIGN.md, "Installing apps on the iPhone", the
/// setup): the person's teams in Xcode, a bundle id prefix for their apps, and whether their signing covers the
/// iPhone. The iPhone's own state (trust, Developer Mode) comes from App/Resources/aos-devices-setup.py.
public enum IPhoneDevSetup {
    /// A developer team the person signed in to in Xcode.
    public struct Team: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// A free Apple account ("Personal Team"): no wildcard App IDs, profiles for 7 days.
        public var isFree: Bool

        public init(id: String, name: String, isFree: Bool) {
            self.id = id
            self.name = name
            self.isFree = isFree
        }
    }

    /// Xcode's teams from its preferences (`IDEProvisioningTeamByIdentifier`: account → teams), paid ones first.
    public static func teams(from value: Any?) -> [Team] {
        guard let accounts = value as? [String: Any] else { return [] }
        var teams: [Team] = []
        for key in accounts.keys.sorted() {
            guard let list = accounts[key] as? [[String: Any]] else { continue }
            for entry in list {
                guard let id = entry["teamID"] as? String, !teams.contains(where: { $0.id == id }) else { continue }
                let free = (entry["isFreeProvisioningTeam"] as? Bool) ?? ((entry["isFreeProvisioningTeam"] as? Int) == 1)
                teams.append(Team(id: id, name: entry["teamName"] as? String ?? id, isFree: free))
            }
        }
        return teams.sorted { $0.isFree != $1.isFree ? !$0.isFree : $0.name < $1.name }
    }

    public static func xcodeTeams() -> [Team] {
        teams(from: CFPreferencesCopyAppValue("IDEProvisioningTeamByIdentifier" as CFString, "com.apple.dt.Xcode" as CFString))
    }

    /// Xcode in /Applications (or wherever xcode-select points).
    public static func xcodeInstalled(fileManager: FileManager = .default) -> Bool {
        if fileManager.fileExists(atPath: "/Applications/Xcode.app") { return true }
        let apps = (try? fileManager.contentsOfDirectory(atPath: "/Applications")) ?? []
        return apps.contains { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
    }

    /// A prefix for the team's wildcard App ID: the one an existing wildcard profile of the team has, else
    /// "com.<team name>".
    public static func suggestedPrefix(team: Team, profiles: [ProvisioningProfile]) -> String {
        var existing: [String] = []
        for profile in profiles where profile.teamID == team.id && profile.isWildcard {
            let pattern = String(profile.applicationIdentifier.dropFirst(team.id.count + 1))
            if pattern.hasSuffix(".*") { existing.append(String(pattern.dropLast(2))) }
        }
        if let prefix = existing.sorted().first { return prefix }
        let folded = team.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let name = String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
            .map(Character.init))
        return "com." + (name.isEmpty ? "example" : name)
    }

    /// Reverse-DNS with at least two parts: letters, digits and hyphens.
    public static func isValidPrefix(_ prefix: String) -> Bool {
        let parts = prefix.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
            }
        }
    }

    public static func setupBundleID(prefix: String) -> String { prefix + ".aossetup" }

    /// Whether the person's signing reaches the iPhone.
    public enum Signing: Equatable, Sendable {
        /// No development certificate (Apple Development) in the keychain yet.
        case noCertificate
        /// No profile for the iPhone yet (the setup app wasn't built in Xcode yet, or the iPhone isn't in it).
        case noProfile
        /// Only profiles for single apps (a free team, or no wildcard App ID): apps install only with their own.
        case exactOnly
        /// A wildcard profile signs every app under `pattern` ("dev.example.*") on the iPhone.
        case ready(pattern: String, profile: String, expires: Date)
    }

    public static func signing(_ signer: IOSAppSigner, team: String, prefix: String, udid: String?) -> Signing {
        let development = signer.identities.filter {
            $0.name.hasPrefix("Apple Development:") || $0.name.hasPrefix("iPhone Developer:")
        }
        guard !development.isEmpty else { return .noCertificate }
        guard let udid else { return .noProfile }
        let usable = signer.profiles.filter { profile in
            profile.expiration > signer.now && profile.covers(device: udid)
                && (team.isEmpty || profile.teamID == team)
                && (profile.platforms.isEmpty || profile.platforms.contains("iOS"))
                && development.contains { profile.certificateFingerprints.contains($0.fingerprint) }
        }
        // A wildcard for the chosen prefix first; one for another prefix works too (agents learn it from iphone_status).
        let wildcards = usable.filter(\.isWildcard).sorted { $0.expiration > $1.expiration }
        let probe = prefix + ".anyapp"
        if let wildcard = wildcards.first(where: { !prefix.isEmpty && $0.covers(bundleID: probe) }) ?? wildcards.first {
            return .ready(pattern: String(wildcard.applicationIdentifier.dropFirst(wildcard.teamID.count + 1)),
                          profile: wildcard.name, expires: wildcard.expiration)
        }
        return usable.isEmpty ? .noProfile : .exactOnly
    }
}
