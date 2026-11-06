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
