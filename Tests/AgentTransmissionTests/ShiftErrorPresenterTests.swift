import XCTest
@testable import AgentTransmission

final class ShiftErrorPresenterTests: XCTestCase {
    func testActiveTurnBecomesBusyMessage() {
        let error = T3CodeClientError.rpcFailure(
            "Thread 68543dfe-b64c-4f1f-90c2-8fee966ea02c has an active turn. Wait for it to finish before changing settings."
        )
        let presented = ShiftErrorPresenter.present(error)
        XCTAssertEqual(presented.headline, "Thread Is Busy")
        XCTAssertFalse(presented.detail.contains("68543dfe"))
    }

    func testUnknownFailureStripsPrefixAndIDs() {
        let presented = ShiftErrorPresenter.present(
            T3CodeClientError.rpcFailure("thread 68543dfe-b64c-4f1f-90c2-8fee966ea02c is locked. Extra internals here.")
        )
        XCTAssertEqual(presented.headline, "Shift Rejected")
        XCTAssertEqual(presented.detail, "This thread is locked.")
    }

    func testTimeoutIsFriendly() {
        XCTAssertEqual(ShiftErrorPresenter.present(T3CodeClientError.rpcTimeout("x")).headline, "No Response")
    }
}
