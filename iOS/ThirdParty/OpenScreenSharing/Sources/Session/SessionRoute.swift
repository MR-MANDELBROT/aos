// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import Foundation

nonisolated struct SessionRoute: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var computerID: UUID?
    var name: String
    var host: String
    var port: Int
    var username: String?
    var credentials: SessionCredentials?
    var model: String?
    var remoteProtocol: RemoteProtocol
    var usesHighPerformance: Bool
    var deviceType: DeviceType?
    var server: ServerAuthentication?
    /// aOS: false when the login comes from aOS (the workspace's sealed login, the Mac's behind Face ID). Then the
    /// session never asks for one and keeps none: no sign-in sheet, no saved password or user name, and a refused
    /// login ends the session for aOS to handle.
    var managesLogin = true
    /// aOS: aOS gives the screen the window's shape itself (the workspace's display request); the session sends no
    /// virtual display of its own for it. Like a virtual display, the picture follows the iPhone in every orientation.
    var followsWindowShape = false
    /// aOS: the connection isn't authenticated by its way (aOS's direct path to the Mac, outside the SSH tunnel): only
    /// Apple's RSA login, and only with the screen sharing key aOS learned through SSH (`trustedFingerprint`).
    var requiresTrustedKey = false

    var address: ComputerAddress {
        ComputerAddress(host: host, port: port)
    }

    var knownPlatform: RemotePlatform? {
        if remoteProtocol == .rdp { return .pc }
        return (deviceType ?? model.flatMap(DeviceType.init(model:))).map { $0.isIOS ? .iOS : .mac }
    }

    init(computer: Computer) {
        computerID = computer.id
        name = computer.displayName
        host = computer.host
        port = computer.port
        username = computer.username.isEmpty ? nil : computer.username
        model = computer.model.isEmpty ? nil : computer.model
        remoteProtocol = computer.remoteProtocol
        usesHighPerformance = computer.usesHighPerformance
        deviceType = computer.usesHighPerformance ? computer.deviceType : nil
    }

    /// aOS: a screen aOS reaches through its SSH tunnel (127.0.0.1 and the forwarded port), with its login, in
    /// standard mode: high performance needs a direct UDP path, and only TCP goes through SSH. Or the Mac on aOS's
    /// direct path (its address on the network), with high performance and the virtual display.
    init(computerID: UUID, name: String, host: String, port: Int, credentials: SessionCredentials, followsWindowShape: Bool,
         usesHighPerformance: Bool = false, requiresTrustedKey: Bool = false) {
        self.computerID = computerID
        self.name = name
        self.host = host
        self.port = port
        username = nil
        self.credentials = credentials
        model = nil
        remoteProtocol = .vnc
        self.usesHighPerformance = usesHighPerformance
        self.requiresTrustedKey = requiresTrustedKey
        deviceType = .mac
        managesLogin = false
        self.followsWindowShape = followsWindowShape
    }

    private enum CodingKeys: String, CodingKey {
        case id, computerID, name, host, port, username, model, remoteProtocol, usesHighPerformance, deviceType, server
    }
}

enum WindowCredentials {
    private static var credentials: [UUID: SessionCredentials] = [:]

    static func send(_ route: SessionRoute) -> SessionRoute {
        var route = route
        credentials[route.id] = route.credentials
        route.credentials = nil
        return route
    }

    static func receive(_ route: SessionRoute) -> SessionRoute {
        var route = route
        route.credentials = credentials.removeValue(forKey: route.id)
        return route
    }
}
