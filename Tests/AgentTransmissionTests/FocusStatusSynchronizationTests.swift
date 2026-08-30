import XCTest
@testable import AgentTransmissionCore
@testable import CodexTransmission

final class FocusStatusSynchronizationTests: XCTestCase {
    func testRequestsStatusWhenTasksArriveAfterControlConnects() {
        var synchronizer = FocusStatusSynchronizer()

        XCTAssertNil(synchronizer.controlDidConnect())
        XCTAssertEqual(synchronizer.tasksDidChange([task("newest")]), "newest")
    }

    func testRequestsStatusWhenControlConnectsAfterTasksArrive() {
        var synchronizer = FocusStatusSynchronizer()

        XCTAssertNil(synchronizer.tasksDidChange([task("newest")]))
        XCTAssertEqual(synchronizer.controlDidConnect(), "newest")
    }

    func testReconnectRetainsAnchorAndRequestsFreshStatus() {
        var synchronizer = FocusStatusSynchronizer()
        _ = synchronizer.tasksDidChange([task("newest")])
        _ = synchronizer.controlDidConnect()

        synchronizer.controlDidDisconnect()

        XCTAssertEqual(synchronizer.controlDidConnect(), "newest")
    }

    func testRoutineTaskRefreshDoesNotRepeatStatusRequest() {
        var synchronizer = FocusStatusSynchronizer()
        _ = synchronizer.controlDidConnect()

        XCTAssertEqual(synchronizer.tasksDidChange([task("newest")]), "newest")
        XCTAssertNil(synchronizer.tasksDidChange([task("newest")]))
    }

    func testStatusRequestMatchesCodexIPCContract() throws {
        let message = CodexDesktopIPCClient.followingStatusRequest(
            clientID: "client-id",
            anchorThreadID: "thread-id"
        )

        XCTAssertEqual(message["type"] as? String, "broadcast")
        XCTAssertEqual(message["sourceClientId"] as? String, "client-id")
        XCTAssertEqual(message["version"] as? Int, 1)
        XCTAssertEqual(message["method"] as? String, "thread-stream-following-status-requested")
        let params = try XCTUnwrap(message["params"] as? [String: Any])
        XCTAssertEqual(params["conversationId"] as? String, "thread-id")
        XCTAssertEqual(params["hostId"] as? String, "local")
    }

    private func task(_ id: String) -> AgentTask {
        AgentTask(id: id, title: id, workspace: "test", updatedAt: 1)
    }
}
