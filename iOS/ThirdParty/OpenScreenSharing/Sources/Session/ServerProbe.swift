// Based on Open Screen Sharing by nekohasekai, GPL-3.0 (iOS/ThirdParty/OpenScreenSharing/LICENSE, COPYING).
// From https://github.com/nekohasekai/open-screen-sharing (fork, branch autofill-passwort, 8b19fc9), taken on
// 2026-11-07; aOS's changes are marked "aOS:".

import Foundation
import Libsharing

nonisolated struct ServerAuthentication: Codable, Hashable, Sendable {
    var account: Bool
    var requestPermission: Bool
    var vncPassword: Bool
    var noPassword: Bool
    var grantsRequests: Bool

    var openCredentials: SessionCredentials? {
        if noPassword {
            return .noAuthentication
        }
        if grantsRequests {
            return .askForPermission(username: "")
        }
        return nil
    }
}

nonisolated struct ProbedServer: Hashable, Sendable {
    var address: ComputerAddress
    var remoteProtocol: RemoteProtocol
    var authentication: ServerAuthentication
    var fingerprint: String
}

nonisolated struct LoginCheck: Sendable {
    var supportsHighPerformance: Bool
    var fingerprint: String
    /// aOS: the security types the server offered and the one used (libsharing's LoginCheck.Security, aOS's patch).
    var security = ""
}

nonisolated enum ServerProber {
    static func probe(host: String, port: Int?, remoteProtocol: RemoteProtocol?) async -> Result<ProbedServer, SessionFailure> {
        let request = UncheckedSendable(value: LibsharingNewProbeRequest()!)
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { () -> Result<ProbedServer, SessionFailure> in
                LibsharingLog.installed
                let probe: LibsharingServerProbe =
                    switch remoteProtocol {
                    case .vnc: request.value.probeServer(host, port: Int32(port ?? RemoteProtocol.vnc.defaultPort))!
                    case .rdp: request.value.probeRDPServer(host, port: Int32(port ?? RemoteProtocol.rdp.defaultPort))!
                    case nil: request.value.probeProtocol(host, port: Int32(port ?? 0))!
                    }
                guard probe.errorCode == LibsharingErrorNone else {
                    return .failure(failure(code: probe.errorCode, message: probe.errorMessage, fingerprint: probe.fingerprint))
                }
                return .success(
                    ProbedServer(
                        address: ComputerAddress(host: host, port: Int(probe.port)),
                        remoteProtocol: probe.protocol == LibsharingProtocolRDP ? .rdp : .vnc,
                        authentication: ServerAuthentication(
                            account: probe.supportsAccount,
                            requestPermission: probe.supportsRequestControl || probe.supportsRequestObserve,
                            vncPassword: probe.supportsVNCPassword,
                            noPassword: probe.supportsNoPassword,
                            grantsRequests: probe.grantsRequests
                        ),
                        fingerprint: probe.fingerprint
                    ))
            }.value
        } onCancel: {
            request.value.cancel()
        }
    }

    static func checkLogin(_ server: ProbedServer, credentials: SessionCredentials) async -> Result<LoginCheck, SessionFailure> {
        let request = UncheckedSendable(value: LibsharingNewProbeRequest()!)
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { () -> Result<LoginCheck, SessionFailure> in
                LibsharingLog.installed
                let options = LibsharingNewSessionOptions()!
                options.protocol = server.remoteProtocol == .rdp ? LibsharingProtocolRDP : LibsharingProtocolRFB
                options.host = server.address.host
                options.port = Int32(server.address.port)
                options.trustedFingerprint = server.fingerprint
                credentials.apply(to: options, observes: false)
                let check = request.value.checkLogin(options)!
                guard check.errorCode == LibsharingErrorNone else {
                    return .failure(failure(code: check.errorCode, message: check.errorMessage, fingerprint: check.fingerprint))
                }
                return .success(LoginCheck(supportsHighPerformance: check.supportsHighPerformance, fingerprint: check.fingerprint,
                                           security: check.security))
            }.value
        } onCancel: {
            request.value.cancel()
        }
    }

    private static func failure(code: Int32, message: String, fingerprint: String) -> SessionFailure {
        switch code {
        case LibsharingErrorAuthentication: SessionFailure(.authenticationFailed, message: message)
        case LibsharingErrorPermissionDenied: SessionFailure(.permissionDenied, message: message)
        case LibsharingErrorHostNotFound: SessionFailure(.hostNotFound, message: message)
        case LibsharingErrorOwnScreen: SessionFailure(.ownScreen, message: message)
        case LibsharingErrorNetwork: SessionFailure(.unreachable, message: message)
        case LibsharingErrorUnsupportedServer: SessionFailure(.unsupported, message: message)
        case LibsharingErrorCertificateChanged: SessionFailure(.certificateChanged(fingerprint: fingerprint), message: message)
        case LibsharingErrorUnverifiedServer: SessionFailure(.unverifiedServer, message: message)
        default: SessionFailure(.other, message: message)
        }
    }
}
