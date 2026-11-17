@testable import AOSKit
import XCTest

/// A slow workspace (HostMemory.swift, WorkspaceController.withDeadline).
final class SlowWorkspaceTests: XCTestCase {
    func testReadsTheMacsMemory() {
        let m = HostMemory.read()
        XCTAssertTrue((0...100).contains(m.freePercent))
        XCTAssertGreaterThanOrEqual(m.swapTotalMiB, m.swapUsedMiB)
        XCTAssertTrue(HostMemory(freePercent: 10, swapUsedMiB: 0, swapTotalMiB: 0).tight)
        XCTAssertTrue(HostMemory(freePercent: 40, swapUsedMiB: 7000, swapTotalMiB: 8192).tight)
        XCTAssertFalse(HostMemory(freePercent: 40, swapUsedMiB: 1000, swapTotalMiB: 8192).tight)
    }

    func testAnswersInTimeAndOnlyOnce() async throws {
        let fast = try await WorkspaceController.withDeadline(2, op: "click") { 42 }
        XCTAssertEqual(fast, 42)
        let started = Date()
        do {
            _ = try await WorkspaceController.withDeadline(0.3, op: "screenshot") { () async throws -> Int in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return 1
            }
            XCTFail("no deadline")
        } catch WorkspaceError.slow(let op, _) {
            XCTAssertEqual(op, "screenshot")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "answered at the deadline, not when the work ended")
        do {
            _ = try await WorkspaceController.withDeadline(2, op: "type") { () async throws -> Int in
                throw WorkspaceError.notOpen
            }
            XCTFail("error lost")
        } catch WorkspaceError.notOpen {}
    }
}
