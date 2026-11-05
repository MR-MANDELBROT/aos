import Foundation
import ObjectiveC
import Virtualization

/// A VNC server on the hypervisor level (Virtualization's private _VZVNCServer, as Tart's --vnc-experimental uses it).
/// It shows the VM's display without anything set up in the guest. DEVELOPMENT ONLY (annexctl): private API.
@MainActor
public final class HypervisorVNC {
    private var server: NSObject?

    public init() {}

    /// Starts the server for `machine` on a free localhost port with a VNC password; returns the port.
    public func start(machine: VZVirtualMachine, password: String) throws -> UInt16 {
        guard let securityClass = NSClassFromString("_VZVNCAuthenticationSecurityConfiguration") as? NSObject.Type,
              let serverClass = NSClassFromString("_VZVNCServer") as? NSObject.Type else {
            throw VMHostError.invalidState("no hypervisor VNC in this macOS")
        }
        let security = securityClass.init()
        typealias InitPassword = @convention(c) (AnyObject, Selector, NSString) -> AnyObject
        let initPassword = unsafeBitCast(class_getMethodImplementation(securityClass, NSSelectorFromString("initWithPassword:")),
                                         to: InitPassword.self)
        let configured = initPassword(securityClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue(),
                                      NSSelectorFromString("initWithPassword:"), password as NSString)
        _ = security
        typealias InitServer = @convention(c) (AnyObject, Selector, UInt16, DispatchQueue, AnyObject) -> AnyObject
        let initServer = unsafeBitCast(class_getMethodImplementation(serverClass, NSSelectorFromString("initWithPort:queue:securityConfiguration:")),
                                       to: InitServer.self)
        let allocated = serverClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        guard let server = initServer(allocated, NSSelectorFromString("initWithPort:queue:securityConfiguration:"),
                                      0, DispatchQueue.global(), configured) as? NSObject else {
            throw VMHostError.invalidState("hypervisor VNC did not start")
        }
        server.perform(NSSelectorFromString("setVirtualMachine:"), with: machine)
        server.perform(NSSelectorFromString("start"))
        self.server = server
        typealias GetPort = @convention(c) (AnyObject, Selector) -> UInt16
        let getPort = unsafeBitCast(class_getMethodImplementation(serverClass, NSSelectorFromString("port")), to: GetPort.self)
        return getPort(server, NSSelectorFromString("port"))
    }

    /// The port, once the server listens (0 before).
    public var port: UInt16 {
        guard let server, let cls = object_getClass(server) else { return 0 }
        typealias GetPort = @convention(c) (AnyObject, Selector) -> UInt16
        let getPort = unsafeBitCast(class_getMethodImplementation(cls, NSSelectorFromString("port")), to: GetPort.self)
        return getPort(server, NSSelectorFromString("port"))
    }

    public func stop() {
        server?.perform(NSSelectorFromString("stop"))
        server = nil
    }
}
