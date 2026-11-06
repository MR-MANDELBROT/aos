import Darwin
import Foundation

/// A raw byte connection to a Unix domain socket (the session's terminal relay).
public final class RawSocket: @unchecked Sendable {
    private let fd: Int32
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "\(Brand.bundleIdentifierPrefix).raw")

    public init(path: URL) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd); throw SocketError.system("socket path", ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { Darwin.close(fd); throw SocketError.notRunning(path.path) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Delivers incoming bytes on the main queue; `onClose` when the other side goes away.
    public func receive(_ handler: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(self.fd, &buffer, buffer.count)
            if n <= 0 {
                self.source?.cancel()
                DispatchQueue.main.async { onClose() }
                return
            }
            let data = Data(buffer[0..<n])
            DispatchQueue.main.async { handler(data) }
        }
        src.resume()
        source = src
    }

    public func send(_ data: Data) {
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }

    public func close() {
        source?.cancel()
        source = nil
        Darwin.close(fd)
    }
}
