import Foundation

// aOS's own Tailscale node on the Mac (Docs/DESIGN.md, "Reaching the Mac on the go"). Its keys must not be files of
// the person: a program that runs as the person (a coding agent with a shell) could copy them and pose as this Mac in
// the tailnet. So aOS's root helper (aos-powerd) runs the node, aos-tailnet (Go, tsnet), as the hidden user
// `_aostailnet`, with its state in /Library/Application Support/aOS/Tailscale (0700, that user). The app asks the
// helper over XPC (`PowerHelperXPC.tailnet`, only the signed aOS app may) to start, stop, sign out or report; it
// never sees a key. The node forwards port 22 of its tailnet address to the Mac's SSH server and offers nothing else.

/// One request to the helper's tailnet node (JSON over its XPC connection).
public struct TailnetRequest: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable {
        /// Whether the node is on and its Tailscale status (with the sign-in URL while it waits for one).
        case status
        /// Starts the node with `hostname` (made the first time) and keeps it on, also after restarts, until stop or
        /// logout.
        case start
        /// Stops the node; its state stays (no new sign-in needed to start it again).
        case stop
        /// A new sign-in URL.
        case login
        /// Starts the node's process again.
        case reconnect
        /// Signs out (the device leaves the tailnet), stops the node and deletes its state.
        case logout
    }

    public var op: Op
    /// For start: the node's name, "aos-" and the Mac's name (see `TailnetRequest.hostname(forMac:)`).
    public var hostname: String?

    public init(op: Op, hostname: String? = nil) {
        self.op = op
        self.hostname = hostname
    }

    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> TailnetRequest? { try? JSONDecoder().decode(TailnetRequest.self, from: data) }

    /// What the helper refuses (nil: fine). A name is a DNS label that starts with "aos-": the node is recognizably
    /// aOS's in the tailnet, and nothing else can reach the node's command line.
    public var problem: String? {
        switch op {
        case .start:
            guard let hostname else { return "no host name" }
            return Self.isValidHostname(hostname) ? nil : "invalid host name"
        default:
            return hostname == nil ? nil : "unexpected host name"
        }
    }

    public static func isValidHostname(_ name: String) -> Bool {
        name.hasPrefix("aos-") && name.utf8.count <= 63 && !name.hasSuffix("-")
            && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// "aos-" and the Mac's local host name in lowercase, other characters as hyphens, at most 63 characters
    /// ("Maxs-MacBook-Pro" -> "aos-maxs-macbook-pro").
    public static func hostname(forMac name: String) -> String {
        var label = ""
        for scalar in name.lowercased().unicodeScalars {
            let ok = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
            if ok { label.unicodeScalars.append(scalar) } else if !label.hasSuffix("-") && !label.isEmpty { label += "-" }
        }
        while label.hasSuffix("-") { label.removeLast() }
        if label.isEmpty { label = "mac" }
        var result = "aos-" + label
        if result.utf8.count > 63 { result = String(result.prefix(63)) }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }
}

/// The helper's answer.
public struct TailnetReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var message: String?
    /// The node is meant to run (it starts again with the helper and after a restart of the Mac).
    public var enabled: Bool?
    /// Its process runs right now.
    public var running: Bool?
    public var hostname: String?
    /// Tailscale's status JSON from the node (TailnetStatus(json:)).
    public var statusJSON: String?
    /// The last problem of the node's process (it ended, it couldn't start).
    public var problem: String?

    public init(ok: Bool, message: String? = nil) {
        self.ok = ok
        self.message = message
    }

    public static func failure(_ message: String) -> TailnetReply { TailnetReply(ok: false, message: message) }

    public var status: TailnetStatus? { statusJSON.flatMap { try? TailnetStatus(json: Data($0.utf8)) } }

    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data("{\"ok\":false}".utf8) }
    public static func decode(_ data: Data) -> TailnetReply {
        (try? JSONDecoder().decode(TailnetReply.self, from: data)) ?? .failure("unreadable answer")
    }
}
