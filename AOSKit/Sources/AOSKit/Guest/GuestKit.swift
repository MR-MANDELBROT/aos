import Foundation

/// Chrome policies for the account in the guest. Sign-ins expire when the workspace shuts down, except on the
/// domains in `keepSignedIn` (fewer captchas there), or never (`keepAll`).
public struct ChromePolicies: Sendable, Equatable {
    public var keepSignedIn: [String]
    /// Every website stays signed in (cookies are kept).
    public var keepAll: Bool

    public init(keepSignedIn: [String] = ["[*.]google.com"], keepAll: Bool = false) {
        self.keepSignedIn = keepSignedIn
        self.keepAll = keepAll
    }

    public func plist() throws -> Data {
        let policies: [String: Any] = [
            "AutofillAddressEnabled": false,
            "AutofillCreditCardEnabled": false,
            "PasswordManagerEnabled": false,
            "PasswordLeakDetectionEnabled": false,
            "BrowserSignin": 0,
            "SyncDisabled": true,
            "DefaultCookiesSetting": keepAll ? 1 : 4,   // cookies kept, or for the session only ...
            "CookiesAllowedForUrls": keepAll ? [] : keepSignedIn,  // ... except these
            "ClearBrowsingDataOnExitList": ["browsing_history", "download_history", "cached_images_and_files",
                                            "password_signin", "autofill", "site_settings", "hosted_app_data"],
            // No prompts that cover the page: promotions, translation and sandbox prompts off. Chrome ignores
            // "sensitive" policies on Macs without MDM (DefaultSearchProvider*, RestoreOnStartup), so the search
            // engine choice appears once per workspace; the agent answers it and Chrome keeps the answer.
            "PromotionsEnabled": false,
            "TranslateEnabled": false,
            "PrivacySandboxPromptEnabled": false,
            "PrivacySandboxAdTopicsEnabled": false,
            "PrivacySandboxSiteEnabledAdsEnabled": false,
            "PrivacySandboxAdMeasurementEnabled": false,
            "DefaultBrowserSettingEnabled": false,
            "MetricsReportingEnabled": false,
            // No DevTools: they could read a filled password back out of the page.
            "DeveloperToolsAvailability": 2,
            "ExtensionInstallBlocklist": ["*"],
            "RemoteDebuggingAllowed": false,
            // Chrome's own pages are closed except the few a browser needs: chrome://net-export and the tracing
            // pages could record a filled sign-in, others reveal or change too much.
            "URLBlocklist": ["javascript:*", "view-source:*", "chrome://*", "chrome-untrusted://*",
                             "chrome-devtools://*", "devtools://*", "chrome://settings/passwords",
                             "chrome://settings/autofill", "chrome://settings/addresses", "chrome://settings/payments"],
            "URLAllowlist": ["chrome://newtab", "chrome://new-tab-page", "chrome://new-tab-page-third-party",
                             "chrome-untrusted://new-tab-page", "chrome://search-engine-choice", "chrome://downloads",
                             "chrome://print", "chrome://welcome", "chrome://intro", "chrome://profile-picker",
                             "chrome://whats-new", "chrome://history", "chrome://settings"],
        ]
        return try PropertyListSerialization.data(fromPropertyList: policies, format: .xml, options: 0)
    }
}

/// The files that go into the guest, and the bootstrap script that carries them there.
public struct GuestKit: Sendable {
    public static let libexec = "/usr/local/libexec/aos"
    public static let serviceLabel = "\(Brand.bundleIdentifierPrefix).guest"
    public static let log = "/var/log/aos-guest.log"

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

    /// The package's resource bundle. Looked up by hand: SwiftPM's Bundle.module stops the process when it can't
    /// find the bundle, which must never happen to the app.
    static let resources: Bundle? = {
        let name = "AOSKit_AOSKit.bundle"
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL, exe, exe.appendingPathComponent("../Resources")]
            .compactMap { $0?.appendingPathComponent(name) }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let b = Bundle(url: url) { return b }
        }
        return nil
    }()

    static func resource(_ name: String) throws -> Data {
        let bundle = resources ?? Bundle.module
        guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Guest"),
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
            ("prepare.sh", try Self.resource("prepare.sh")),
            ("helper.sh", try Self.resource("helper.sh")),
            ("update.sh", try Self.resource("update.sh")),
            ("chrome.plist", try policies.plist()),
            ("settings.env", Data(settingsEnv().utf8)),
            ("maintenance.pub", Data((maintenancePublicKey + "\n").utf8)),
            ("stop.pub", Data((stopPublicKey + "\n").utf8)),
        ] + Self.helperFiles()
    }

    /// The workspace helper, packed (the app ships it as Resources/AOSHelper.app; development builds don't have it).
    /// Where the helper app is: in the app bundle, or (development tools) at AOS_HELPER_APP.
    static let helperApp: URL? = {
        if let path = ProcessInfo.processInfo.environment["AOS_HELPER_APP"], !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return Bundle.main.url(forResource: "AOSHelper", withExtension: "app")
    }()

    static let helperArchive: Data? = {
        guard let app = helperApp else { return nil }
        guard let r = try? Subprocess.runBlocking(
            "/usr/bin/tar", ["-czf", "-", "--no-xattrs", "--no-mac-metadata", "-C", app.deletingLastPathComponent().path,
                             "AOSHelper.app"],
            environment: ["COPYFILE_DISABLE": "1", "PATH": "/usr/bin:/bin"], timeout: 60) else { return nil }
        return r.status == 0 && !r.stdout.isEmpty ? r.stdout : nil
    }()

    /// What identifies the helper's version (the archive itself changes with every packing).
    static let helperDigest: Data = {
        guard let app = helperApp else { return Data() }
        var d = Data()
        for part in ["Contents/MacOS/AOSHelper", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"] {
            d.append(FileManager.default.contents(atPath: app.appendingPathComponent(part).path) ?? Data())
        }
        return d
    }()

    static func helperFiles() -> [(String, Data)] {
        helperArchive.map { [("AOSHelper.tgz", $0)] } ?? []
    }

    /// A fingerprint of everything the kit puts into the guest (without the keys): when it changes (an app update),
    /// a set-up workspace gets the new files at its next opening.
    public func fingerprint() throws -> String {
        var data = try Self.resource("setup.sh")
        for (name, file) in try updateFiles() where name != "AOSHelper.tgz" { data.append(file) }
        data.append(Self.helperDigest)
        var hash = 0xcbf29ce484222325 as UInt64
        for b in data { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    /// The files an update needs (no keys: those stay as they are).
    public func updateFiles() throws -> [(String, Data)] {
        [
            ("update.sh", try Self.resource("update.sh")),
            ("guest-service.sh", try Self.resource("guest-service.sh")),
            ("shutdown.sh", try Self.resource("shutdown.sh")),
            ("finish.sh", try Self.resource("finish.sh")),
            ("prepare.sh", try Self.resource("prepare.sh")),
            ("helper.sh", try Self.resource("helper.sh")),
            ("chrome.plist", try policies.plist()),
            ("settings.env", Data(settingsEnv().utf8)),
        ] + Self.helperFiles()
    }

    /// A self-contained zsh script: unpacks the files into a private temporary folder, runs `entry` with that
    /// folder as argument, removes the folder. Runs as root in the guest.
    public static func bundleScript(files: [(String, Data)], entry: String) -> String {
        var s = "#!/bin/zsh -f\nset -eu\numask 077\nK=\"$(mktemp -d /var/root/aos-kit.XXXXXX)\"\n"
        s += "trap 'rm -rf \"$K\"' EXIT\n"
        for (name, data) in files {
            precondition(safe(name) != nil, "kit file names are fixed")
            s += "/usr/bin/base64 -D -o \"$K/\(name)\" <<'AOS_B64'\n"
            s += data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
            s += "\nAOS_B64\n"
        }
        s += "/bin/zsh -f \"$K/\(entry)\" \"$K\"\n"
        return s
    }
}
