import Foundation

/// One request to the agent (one JSON line). `op` names the operation; the other fields are its arguments.
public struct AgentRequest: Codable, Sendable {
    public var id: Int
    public var op: String
    public var purpose: String?
    public var minutes: Int?
    public var x: Double?
    public var y: Double?
    public var toX: Double?
    public var toY: Double?
    public var button: String?
    public var count: Int?
    public var modifiers: String?
    public var direction: String?
    public var steps: Int?
    public var text: String?
    public var keys: String?
    public var seconds: Double?
    public var image: Bool?
    public var path: String?
    public var name: String?
    public var keep: Bool?
    public var region: [Double]?
    /// How opening was approved: "agent" (the agent asked), "elicited" (the user said yes through the agent),
    /// "mac" (aOS must ask on the Mac).
    public var approval: String?
    /// Which agent calls (AOS_AGENT, or the MCP client's name).
    public var agent: String?

    // Companion (iPhone) operations
    /// The request a companion answers (sign-in, help, approval).
    public var request: String?
    public var username: String?
    public var password: String?
    public var totp: String?
    /// signin.answer: the Bitwarden login the user approved (its id; aOS gets the secrets from Bitwarden).
    public var login: String?
    public var decline: Bool?
    public var allowed: Bool?
    /// companion.events: the last sequence number the companion has seen.
    public var since: Int?
    /// companion.screen: "mac" or "workspace".
    public var target: String?
    /// The companion device's name (hello).
    public var device: String?

    public init(id: Int, op: String) { self.id = id; self.op = op }
}

/// The agent's answer (one JSON line).
public struct AgentResponse: Codable, Sendable {
    public var id: Int
    public var ok: Bool
    public var text: String
    /// Base64 image, if the operation returns a screenshot.
    public var image: String?
    public var mimeType: String?

    public init(id: Int, ok: Bool, text: String, image: Data? = nil, mimeType: String? = nil) {
        self.id = id
        self.ok = ok
        self.text = text
        self.image = image?.base64EncodedString()
        self.mimeType = mimeType
    }

    public static func failure(_ id: Int, _ message: String) -> AgentResponse {
        AgentResponse(id: id, ok: false, text: message)
    }
}

/// Status for the app's menu and the status tool.
public struct AgentStatus: Codable, Sendable, Equatable {
    public var vmPhase: String
    public var installed: Bool
    public var setupComplete: Bool
    public var leaseUntil: Date?
    public var leasePurpose: String?
    public var guestAddress: String?
    public var exchangeFiles: Int
    public var lastError: String?
    public var sessionState: String?
}
