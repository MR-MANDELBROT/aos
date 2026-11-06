@testable import AnnexKit
import XCTest

final class SubprocessTests: XCTestCase {
    func testStatusAndOutput() async throws {
        let r = try await Subprocess.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], timeout: 10)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: r.stderr, as: UTF8.self), "err\n")
        XCTAssertFalse(r.timedOut)
    }

    func testTimeoutEndsTheChild() async throws {
        let start = Date()
        let r = try await Subprocess.run("/bin/sleep", ["30"], timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testLargeOutputDoesNotBlock() async throws {
        // Far more than a pipe buffer (64 KB)
        let r = try await Subprocess.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero"], timeout: 20)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.stdout.count, 3_000_000)
    }

    func testInputAndAChildThatIgnoresIt() async throws {
        let echo = try await Subprocess.run("/bin/cat", [], input: Data("hello\n".utf8), timeout: 10)
        XCTAssertEqual(String(decoding: echo.stdout, as: UTF8.self), "hello\n")
        // Exits without reading 1 MB of input: no SIGPIPE for us
        let r = try await Subprocess.run("/usr/bin/true", [], input: Data(count: 1 << 20), timeout: 10)
        XCTAssertEqual(r.status, 0)
    }

    func testGrandchildHoldingThePipeDoesNotHang() async throws {
        let start = Date()
        let r = try await Subprocess.run("/bin/sh", ["-c", "(sleep 30 &); echo spawned"], timeout: 20)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "spawned\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testBlockingFromManyConcurrentTasks() async throws {
        // Many at once must not starve each other (each waits on a thread of its own)
        try await withThrowingTaskGroup(of: Int32.self) { group in
            for _ in 0..<40 { group.addTask { try await Subprocess.run("/bin/sh", ["-c", "sleep 0.2"], timeout: 20).status } }
            for try await status in group { XCTAssertEqual(status, 0) }
        }
    }
}

/// One request over a plain socket (the test's clients and the server share a process; FileHandles that close on
/// dealloc would race over reused descriptor numbers there).
func rawRoundTrip(_ path: URL, _ line: String) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        path.path.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count - 1))) }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else { return nil }
    let data = Array((line + "\n").utf8)
    guard write(fd, data, data.count) == data.count else { return nil }
    var reply = [UInt8]()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 { if byte == 0x0A { break }; reply.append(byte) }
    return String(decoding: reply, as: UTF8.self)
}

final class LineSocketTests: XCTestCase {
    /// A connection that waits (like a phone's long poll) must not hold up the others. The clients run on threads
    /// of their own (their calls block).
    func testSlowConnectionDoesNotBlockOthers() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("annex-ls-\(UUID().uuidString.prefix(8)).sock")
        let server = LineSocketServer(path: path) { line in
            if line == Data("slow".utf8) { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            return line
        }
        try server.start()
        defer { server.stop() }
        // An open connection that sends nothing
        let idle = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(idle) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.path.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count - 1))) }
        }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(idle, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let slowDone = expectation(description: "slow")
        Thread.detachNewThread {
            if rawRoundTrip(path, "slow") == "slow" { slowDone.fulfill() }
        }
        Thread.sleep(forTimeInterval: 0.2)
        let start = Date()
        let fast = expectation(description: "fast")
        fast.expectedFulfillmentCount = 10
        for i in 0..<10 {
            Thread.detachNewThread {
                if rawRoundTrip(path, "fast \(i)") == "fast \(i)" { fast.fulfill() }
            }
        }
        wait(for: [fast], timeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "fast requests waited for the slow one")
        wait(for: [slowDone], timeout: 10)
    }
}
