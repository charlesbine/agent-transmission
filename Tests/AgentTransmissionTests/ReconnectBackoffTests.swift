import XCTest
@testable import CodexTransmission

final class ReconnectBackoffTests: XCTestCase {
    func testDelayDoublesAndCapsAtThirtySeconds() {
        var backoff = ReconnectBackoff()

        XCTAssertEqual((0..<8).map { _ in backoff.nextDelay() }, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testSuccessfulConnectionResetsDelay() {
        var backoff = ReconnectBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        backoff.reset()

        XCTAssertEqual(backoff.nextDelay(), 1)
    }
}
