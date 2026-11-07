// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import Foundation
import Network

nonisolated struct ComputerAddress: Hashable, Sendable, CustomStringConvertible {
    static let defaultPort = 5900

    var host: String
    var port: Int

    init(host: String, port: Int = ComputerAddress.defaultPort) {
        self.host = host
        self.port = port
    }

    var description: String {
        description(defaultPort: Self.defaultPort)
    }

    func description(defaultPort: Int) -> String {
        if port == defaultPort {
            return host
        }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    var bonjourServiceName: String? {
        let lowered = host.lowercased()
        for suffix in ["._rfb._tcp.local.", "._rfb._tcp.local"] where lowered.hasSuffix(suffix) {
            return String(host.dropLast(suffix.count))
        }
        return nil
    }

    func matches(_ other: ComputerAddress) -> Bool {
        port == other.port && Self.normalized(host) == Self.normalized(other.host)
    }

    private static func normalized(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        return value
    }

    static func host(parsing text: String) -> String? {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
            return IPv6Address(host) != nil ? host : nil
        }
        if host.contains(":") {
            return IPv6Address(host) != nil ? host : nil
        }
        return isHostName(host) ? host : nil
    }

    private static func isHostName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 253 else { return false }
        var labels = text.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count > 1, labels.last?.isEmpty == true {
            labels.removeLast()
        }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }
}

nonisolated struct ConnectionTarget: Hashable, Sendable {
    var host: String
    var port: Int?
    var remoteProtocol: RemoteProtocol?
    var username: String?
    var password: String?
}

nonisolated extension ConnectionTarget {
    init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            guard let link = RemoteLink(string: trimmed) else { return nil }
            host = link.address.host
            port = link.address.port
            remoteProtocol = link.remoteProtocol
            username = link.username
            password = link.password
            return
        }
        var rest = Substring(trimmed)
        if let at = rest.lastIndex(of: "@") {
            let name = rest[..<at]
            guard !name.isEmpty else { return nil }
            username = String(name)
            rest = rest[rest.index(after: at)...]
        }
        guard let endpoint = Self.endpoint(parsing: rest) else { return nil }
        host = endpoint.host
        port = endpoint.port
    }

    static func endpoint(parsing text: Substring) -> (host: String, port: Int?)? {
        if text.hasPrefix("[") {
            guard let closing = text.firstIndex(of: "]") else { return nil }
            guard let host = ComputerAddress.host(parsing: String(text[...closing])) else { return nil }
            let suffix = text[text.index(after: closing)...]
            if suffix.isEmpty { return (host, nil) }
            guard suffix.hasPrefix(":"), let port = Int(suffix.dropFirst()), (1...65535).contains(port) else { return nil }
            return (host, port)
        }
        let colons = text.count(where: { $0 == ":" })
        if colons == 1, let colon = text.firstIndex(of: ":") {
            guard let host = ComputerAddress.host(parsing: String(text[..<colon])),
                let port = Int(text[text.index(after: colon)...]), (1...65535).contains(port)
            else { return nil }
            return (host, port)
        }
        guard let host = ComputerAddress.host(parsing: String(text)) else { return nil }
        return (host, nil)
    }
}

nonisolated struct RemoteLink: Hashable, Sendable {
    var address: ComputerAddress
    var remoteProtocol: RemoteProtocol
    var username: String?
    var password: String?

    init?(string: String) {
        guard let separator = string.range(of: "://"),
            let remoteProtocol = RemoteProtocol(rawValue: string[..<separator.lowerBound].lowercased())
        else { return nil }
        if remoteProtocol == .rdp, let attributes = Self.rdpAttributes(string[separator.upperBound...]) {
            guard let full = attributes["full address"], let endpoint = ConnectionTarget.endpoint(parsing: Substring(full)) else { return nil }
            address = ComputerAddress(host: endpoint.host, port: endpoint.port ?? remoteProtocol.defaultPort)
            self.remoteProtocol = remoteProtocol
            if let user = attributes["username"], !user.isEmpty {
                let domain = attributes["domain"] ?? ""
                username = user.contains("\\") || domain.isEmpty ? user : "\(domain)\\\(user)"
            }
            return
        }
        guard let components = URLComponents(string: string) else { return nil }
        let host = components.percentEncodedHost.flatMap { $0.removingPercentEncoding } ?? components.host
        guard let host, !host.isEmpty else { return nil }
        let unbracketed = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        address = ComputerAddress(host: unbracketed, port: components.port ?? remoteProtocol.defaultPort)
        self.remoteProtocol = remoteProtocol
        username = components.user.flatMap { $0.isEmpty ? nil : $0 }
        password = components.password.flatMap { $0.isEmpty && username == nil ? nil : $0 }
    }

    private static func rdpAttributes(_ query: Substring) -> [String: String]? {
        var attributes: [String: String] = [:]
        for pair in query.split(separator: "&") {
            guard let equals = pair.firstIndex(of: "="), let colon = pair[equals...].firstIndex(of: ":"),
                pair.distance(from: equals, to: colon) == 2,
                let key = pair[..<equals].removingPercentEncoding, let value = pair[pair.index(after: colon)...].removingPercentEncoding
            else { return nil }
            attributes[key.lowercased()] = value
        }
        return attributes["full address"] == nil ? nil : attributes
    }
}
