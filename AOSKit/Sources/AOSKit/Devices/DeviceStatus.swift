import Foundation

/// What the device worker reports in `run/devices.json` (App/Resources/aos-devices-worker.py writes it).
public struct DeviceStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// The worker is starting.
        case starting
        /// No tunnel: the worker waits until the iPhone's pairing port answers (the iPhone on any Wi-Fi).
        case searching
        case connecting
        /// The tunnel is up; installs go through it.
        case connected
        /// This Mac holds no pairing record for an iPhone.
        case notPaired
        case stopped
        case unknown

        public init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public struct Device: Codable, Sendable, Equatable {
        public var udid: String
        public var name: String?
        public var ios: String?
        /// The address the tunnel uses (the iPhone's tailnet address) and its name there.
        public var address: String?
        public var addressName: String?
    }

    /// A tunnel that ended: when it came up, how long it held, why it ended.
    public struct Tunnel: Codable, Sendable, Equatable {
        public var from: Date?
        public var seconds: Int
        public var reason: String?
    }

    public var state: State
    public var message: String?
    public var device: Device?
    /// Since when the current tunnel is up.
    public var since: Date?
    /// "wifi" while the iPhone's pairing port answers, "cellular" while it doesn't but the tunnel holds, "offline" while
    /// the iPhone answers no ping (the tunnel waits for it, sending nothing).
    public var network: String?
    public var lastHeartbeat: Date?
    public var updated: Date?
    public var pid: Int32?
    public var history: [Tunnel]
    /// The latest jobs, newest first.
    public var jobs: [DeviceJob]

    public init(state: State = .unknown, message: String? = nil, device: Device? = nil, since: Date? = nil,
                network: String? = nil, lastHeartbeat: Date? = nil, updated: Date? = nil, pid: Int32? = nil,
                history: [Tunnel] = [], jobs: [DeviceJob] = []) {
        self.state = state
        self.message = message
        self.device = device
        self.since = since
        self.network = network
        self.lastHeartbeat = lastHeartbeat
        self.updated = updated
        self.pid = pid
        self.history = history
        self.jobs = jobs
    }

    enum CodingKeys: String, CodingKey {
        case state, message, device, since, network, lastHeartbeat, updated, pid, history, jobs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = (try? c.decode(State.self, forKey: .state)) ?? .unknown
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        device = try? c.decodeIfPresent(Device.self, forKey: .device)
        since = try? c.decodeIfPresent(Date.self, forKey: .since)
        network = try? c.decodeIfPresent(String.self, forKey: .network)
        lastHeartbeat = try? c.decodeIfPresent(Date.self, forKey: .lastHeartbeat)
        updated = try? c.decodeIfPresent(Date.self, forKey: .updated)
        pid = try? c.decodeIfPresent(Int32.self, forKey: .pid)
        history = (try? c.decodeIfPresent([Tunnel].self, forKey: .history)) ?? []
        jobs = (try? c.decodeIfPresent([DeviceJob].self, forKey: .jobs)) ?? []
    }

    /// The tunnel is up and installs go through it now.
    public var isConnected: Bool { state == .connected }
    /// The tunnel is up, but the iPhone is offline right now (installs wait until it's back).
    public var isOffline: Bool { isConnected && network == "offline" }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = DeviceJob.parseDate(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date \(text)"))
        }
        return d
    }

    /// The worker's report, or nil when there is none (the worker never ran) or it can't be read.
    public static func load(_ paths: Paths) -> DeviceStatus? {
        guard let data = FileManager.default.contents(atPath: paths.deviceStatus.path) else { return nil }
        return try? decoder().decode(DeviceStatus.self, from: data)
    }

    /// The report is from a worker that still runs (its pid is alive).
    public func isFresh(alive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Bool {
        guard let pid else { return false }
        return alive(pid)
    }
}

/// One app to install (`Devices/Jobs/<id>.json`). aOS writes it with state `queued`; the worker installs it when the
/// tunnel is up and sets `installing`, then `done` or `failed`.
public struct DeviceJob: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        case queued, installing, done, failed, unknown

        public init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var id: String
    /// The signed app in `Devices/Staging/<id>/` (the worker removes it once installed).
    public var app: String?
    public var name: String
    public var bundleId: String
    public var version: String?
    /// Who asked: an agent's name, or "Mac".
    public var source: String?
    public var created: Date
    public var state: State
    public var message: String?
    public var started: Date?
    public var finished: Date?
    public var seconds: Double?
    /// The iPhone's network while it installed: "wifi" or "cellular".
    public var network: String?

    public init(id: String = UUID().uuidString, app: String?, name: String, bundleId: String, version: String?,
                source: String?, created: Date = Date(), state: State = .queued) {
        self.id = id
        self.app = app
        self.name = name
        self.bundleId = bundleId
        self.version = version
        self.source = source
        self.created = created
        self.state = state
    }

    public var isFinished: Bool { state == .done || state == .failed }

    static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601DateFormatter().string(from: date))
        }
        return e
    }
}
