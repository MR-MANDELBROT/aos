@testable import AOSKit
import XCTest

final class SessionOutputTests: XCTestCase {
    func testOnlyTheLatestSignCounts() {
        let dropped = "⏺Remote Control disconnected — OAuth token refresh failed — run /login to re-authenticate\n"
        XCTAssertEqual(SessionOutput.classify(dropped), .signIn)
        // Claude Code reconnects by itself: the sign-in hint is old news.
        let back = dropped + "some answer\n/remote-control is active · Continue here, on your phone, or at https://claude.ai/code\n"
        XCTAssertEqual(SessionOutput.classify(back), .fine)
        XCTAssertEqual(SessionOutput.classify(back + "Not logged in · Please run /login\n"), .signIn)
        XCTAssertEqual(SessionOutput.classify("Do you trust the files in this folder? [y/N]"), .question)
        XCTAssertEqual(SessionOutput.classify("just some output"), .unknown)
    }
}
