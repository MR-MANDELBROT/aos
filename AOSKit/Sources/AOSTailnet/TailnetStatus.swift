import Foundation

/// A tailnet node's state as Tailscale reports it: the JSON of `tailscale status --json` (Tailscale's
/// `ipnstate.Status`). Read the same way from the person's Tailscale app on the Mac, from aOS's own node on the Mac
/// (through the helper) and from aOS's node in the iPhone app. Unknown fields are ignored, missing ones tolerated.
public struct TailnetStatus: Equatable, Sendable {
    /// Tailscale's backend state: NoState, NeedsLogin, NeedsMachineAuth, Stopped, Starting, Running.
    public var backendState: String
    /// While the node waits for a sign-in: the page that signs it in (whoever completes it first gets the node).
    public var authURL: String?
    /// The tailnet's name (often the account's email address or the organization's domain).
    public var tailnet: String?
    /// The tailnet's DNS suffix ("tail1234.ts.net").
    public var magicDNSSuffix: String?
    /// This device; nil before the first sign-in.
    public var device: TailnetDevice?
    /// The other devices of the tailnet.
    public var peers: [TailnetDevice]
    /// Tailscale's health warnings.
    public var health: [String]
    /// The account this device belongs to (login name).
    public var user: String?

    public init(backendState: String, authURL: String? = nil, tailnet: String? = nil, magicDNSSuffix: String? = nil,
                device: TailnetDevice? = nil, peers: [TailnetDevice] = [], health: [String] = [], user: String? = nil) {
        self.backendState = backendState
        self.authURL = authURL
        self.tailnet = tailnet
        self.magicDNSSuffix = magicDNSSuffix
        self.device = device
        self.peers = peers
        self.health = health
        self.user = user
    }

    public enum ParseError: Error, Equatable { case notJSON, noBackendState }

    /// Parses Tailscale's status JSON.
    public init(json: Data) throws {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw ParseError.notJSON }
        guard let state = o["BackendState"] as? String, !state.isEmpty else { throw ParseError.noBackendState }
        backendState = state
        authURL = (o["AuthURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let current = o["CurrentTailnet"] as? [String: Any]
        tailnet = (current?["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let suffix = (current?["MagicDNSSuffix"] as? String) ?? (o["MagicDNSSuffix"] as? String)
        magicDNSSuffix = suffix.flatMap { $0.isEmpty ? nil : Self.trimDot($0) }
        device = (o["Self"] as? [String: Any]).flatMap(TailnetDevice.init(json:))
        let peerMap = o["Peer"] as? [String: Any] ?? [:]
        peers = peerMap.values.compactMap { ($0 as? [String: Any]).flatMap(TailnetDevice.init(json:)) }
            .sorted { $0.hostName.localizedStandardCompare($1.hostName) == .orderedAscending }
        health = (o["Health"] as? [String]) ?? []
        if let users = o["User"] as? [String: Any], let id = device?.userID,
           let profile = users[String(id)] as? [String: Any] {
            user = (profile["LoginName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    static func trimDot(_ name: String) -> String { name.hasSuffix(".") ? String(name.dropLast()) : name }

    /// Signed in and connected.
    public var isRunning: Bool { backendState == "Running" }
    /// Waits for a sign-in (first time, or after signing out or the key expired).
    public var needsLogin: Bool { backendState == "NeedsLogin" }
    /// Signed in, but an administrator of the tailnet must approve the device first.
    public var needsApproval: Bool { backendState == "NeedsMachineAuth" }

    /// aOS's own devices of the tailnet (their names start with "aos-"), this one first if it is one.
    public var aosDevices: [TailnetDevice] {
        var list = peers.filter(\.isAOS)
        if let device, device.isAOS { list.insert(device, at: 0) }
        return list
    }

    /// The device with this host name (aOS's node of a Mac or an iPhone).
    public func peer(named hostName: String) -> TailnetDevice? {
        peers.first { $0.hostName.caseInsensitiveCompare(hostName) == .orderedSame }
    }
}

/// One device of a tailnet.
public struct TailnetDevice: Equatable, Sendable, Identifiable {
    public var id: String
    /// The name the device registered with (aOS's own: "aos-...").
    public var hostName: String
    /// Its MagicDNS name, without the final dot ("aos-mac.tail1234.ts.net").
    public var dnsName: String
    /// Its tailnet addresses (IPv4 in 100.64.0.0/10 first, then IPv6).
    public var addresses: [String]
    public var os: String?
    public var online: Bool
    public var lastSeen: Date?
    /// When its key expires; nil when key expiry is off for it.
    public var keyExpiry: Date?
    public var expired: Bool
    public var userID: Int64?

    public init(id: String, hostName: String, dnsName: String = "", addresses: [String] = [], os: String? = nil,
                online: Bool = false, lastSeen: Date? = nil, keyExpiry: Date? = nil, expired: Bool = false,
                userID: Int64? = nil) {
        self.id = id
        self.hostName = hostName
        self.dnsName = dnsName
        self.addresses = addresses
        self.os = os
        self.online = online
        self.lastSeen = lastSeen
        self.keyExpiry = keyExpiry
        self.expired = expired
        self.userID = userID
    }

    init?(json o: [String: Any]) {
        let hostName = (o["HostName"] as? String) ?? ""
        let dnsName = TailnetStatus.trimDot((o["DNSName"] as? String) ?? "")
        guard !hostName.isEmpty || !dnsName.isEmpty else { return nil }
        id = (o["ID"] as? String) ?? (o["PublicKey"] as? String) ?? dnsName
        self.hostName = hostName.isEmpty ? String(dnsName.prefix { $0 != "." }) : hostName
        self.dnsName = dnsName
        let ips = (o["TailscaleIPs"] as? [String]) ?? []
        addresses = ips.filter { !$0.contains(":") } + ips.filter { $0.contains(":") }
        os = (o["OS"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        online = (o["Online"] as? Bool) ?? false
        lastSeen = (o["LastSeen"] as? String).flatMap(Self.date)
        keyExpiry = (o["KeyExpiry"] as? String).flatMap(Self.date)
        expired = (o["Expired"] as? Bool) ?? false
        userID = (o["UserID"] as? NSNumber)?.int64Value
    }

    /// aOS's own nodes register as "aos-<device>".
    public var isAOS: Bool { hostName.lowercased().hasPrefix("aos-") }

    /// Its tailnet IPv4 address.
    public var ipv4: String? { addresses.first { !$0.contains(":") } }

    /// Go's RFC 3339 times, with or without fractions; Go's zero time ("0001-01-01T00:00:00Z") is no date.
    static func date(_ text: String) -> Date? {
        guard !text.hasPrefix("0001-") else { return nil }
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractions.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        // Go writes up to nine fraction digits; Foundation reads three.
        if let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = text[text.index(after: dot)..<end]
            return withFractions.date(from: String(text[..<dot]) + "." + digits.prefix(3) + text[end...])
        }
        return nil
    }
}
