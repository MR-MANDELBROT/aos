import Foundation

/// Chrome policies for the account in the guest. Sign-ins expire when the workspace shuts down, except on the
/// domains in `keepSignedIn` (fewer captchas there).
public struct ChromePolicies: Sendable, Equatable {
    public var keepSignedIn: [String]

    public init(keepSignedIn: [String] = ["[*.]google.com"]) { self.keepSignedIn = keepSignedIn }

    public func plist() throws -> Data {
        let policies: [String: Any] = [
            "AutofillAddressEnabled": false,
            "AutofillCreditCardEnabled": false,
            "PasswordManagerEnabled": false,
            "PasswordLeakDetectionEnabled": false,
            "BrowserSignin": 0,
            "SyncDisabled": true,
            "DefaultCookiesSetting": 4,                 // cookies for the session only ...
            "CookiesAllowedForUrls": keepSignedIn,      // ... except these
            "ClearBrowsingDataOnExitList": ["browsing_history", "download_history", "cached_images_and_files",
                                            "password_signin", "autofill", "site_settings", "hosted_app_data"],
            "RestoreOnStartup": 5,
            "DefaultBrowserSettingEnabled": false,
            "MetricsReportingEnabled": false,
            "DeveloperToolsAvailability": 0,
            "ExtensionInstallBlocklist": ["*"],
            "RemoteDebuggingAllowed": false,
            "URLBlocklist": ["javascript:*", "view-source:*", "chrome://inspect", "chrome://extensions",
                             "chrome://flags", "chrome-devtools://*", "devtools://*"],
        ]
        return try PropertyListSerialization.data(fromPropertyList: policies, format: .xml, options: 0)
    }
}

/// The files that go into the guest, and the bootstrap script that carries them there.
public struct GuestKit: Sendable {
    public static let libexec = "/usr/local/libexec/annex"
    public static let serviceLabel = "\(Brand.bundleIdentifierPrefix).guest"
    public static let log = "/var/log/annex-guest.log"

    public var policies: ChromePolicies
    public var languages: [String]
    public var locale: String
    public var timeZone: String

    public init(policies: ChromePolicies = ChromePolicies(),
                languages: [String] = Locale.preferredLanguages,
                locale: String = Locale.current.identifier,
                timeZone: String = TimeZone.current.identifier) {
        self.policies = policies
        self.languages = languages
        self.locale = locale
        self.timeZone = timeZone
    }

    /// Only characters that can't change the meaning of a shell line.
    static func safe(_ value: String) -> String? {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./+@")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) } && !value.isEmpty ? value : nil
    }

    func settingsEnv() -> String {
        let langs = languages.compactMap(Self.safe).prefix(4).joined(separator: " ")
        var lines = [
            "GUEST_USER=\(Brand.guestUser)",
            "LIBEXEC=\(Self.libexec)",
            "SERVICE_LABEL=\(Self.serviceLabel)",
            "LOG=\(Self.log)",
        ]
        lines.append("LANGUAGES=\"\(langs)\"")
        lines.append("LOCALE=\(Self.safe(locale) ?? "")")
        lines.append("TIMEZONE=\(Self.safe(timeZone) ?? "")")
        return lines.joined(separator: "\n") + "\n"
    }

    static func resource(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Guest"),
              let data = FileManager.default.contents(atPath: url.path) else {
            throw VMBundleError.missing("guest file \(name)")
        }
        return data
    }

    /// All kit files by name.
    public func files(maintenancePublicKey: String, stopPublicKey: String) throws -> [(String, Data)] {
        [
            ("setup.sh", try Self.resource("setup.sh")),
            ("guest-service.sh", try Self.resource("guest-service.sh")),
            ("shutdown.sh", try Self.resource("shutdown.sh")),
            ("finish.sh", try Self.resource("finish.sh")),
            ("chrome.plist", try policies.plist()),
            ("settings.env", Data(settingsEnv().utf8)),
            ("maintenance.pub", Data((maintenancePublicKey + "\n").utf8)),
            ("stop.pub", Data((stopPublicKey + "\n").utf8)),
        ]
    }

    /// A self-contained zsh script: unpacks the files into a private temporary folder, runs `entry` with that
    /// folder as argument, removes the folder. Runs as root in the guest.
    public static func bundleScript(files: [(String, Data)], entry: String) -> String {
        var s = "#!/bin/zsh -f\nset -eu\numask 077\nK=\"$(mktemp -d /var/root/annex-kit.XXXXXX)\"\n"
        s += "trap 'rm -rf \"$K\"' EXIT\n"
        for (name, data) in files {
            precondition(safe(name) != nil, "kit file names are fixed")
            s += "/usr/bin/base64 -D -o \"$K/\(name)\" <<'ANNEX_B64'\n"
            s += data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
            s += "\nANNEX_B64\n"
        }
        s += "/bin/zsh -f \"$K/\(entry)\" \"$K\"\n"
        return s
    }
}
