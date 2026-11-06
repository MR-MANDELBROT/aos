import Foundation

/// Which logins belong to a sign-in request (Docs/COMPANION.md, "Matching logins"): a login matches host H when the
/// host of one of its URIs equals H, or is a parent domain of H that still has at least two labels. `amazon.de`
/// matches `www.amazon.de`; `login.tum.de` does not match `campus.tum.de`; `de` matches nothing. IP addresses only
/// match exactly (otherwise `0.0.1` would be a "parent" of `10.0.0.1`). aOS checks the rule when it offers logins
/// for a request and again right before it fills one.
public enum HostMatching {
    /// The host of a URI as people store it: `https://www.amazon.de/login`, `amazon.de`, `amazon.de:8443/x`.
    /// Non-web schemes (`androidapp://`, `iosapp://`) have no web host and return nil.
    public static func host(ofURI uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        let normalized = normalize(host)
        return normalized.isEmpty ? nil : normalized
    }

    /// Lowercased, without a trailing dot or IPv6 brackets.
    public static func normalize(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    public static func matches(uriHost: String, requestHost: String) -> Bool {
        let candidate = normalize(uriHost), target = normalize(requestHost)
        guard !candidate.isEmpty, !target.isEmpty else { return false }
        if candidate == target { return true }
        if isIPAddress(candidate) || isIPAddress(target) { return false }
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return false }
        return target.hasSuffix("." + candidate)
    }

    /// True when any of the URIs matches the requested host.
    public static func matches(uris: [String], requestHost: String) -> Bool {
        uris.contains { uri in host(ofURI: uri).map { matches(uriHost: $0, requestHost: requestHost) } ?? false }
    }

    public static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }  // IPv6
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}
