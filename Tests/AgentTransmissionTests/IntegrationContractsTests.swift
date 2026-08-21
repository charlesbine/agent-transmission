import XCTest
@testable import AgentTransmissionCore

final class IntegrationContractsTests: XCTestCase {
    func testControlSurfaceEmitsSemanticEventsWithoutAgentKnowledge() {
        let surface = FakeControlSurface()
        var received: [ControlSurfaceEvent] = []
        surface.onEvents = { received.append(contentsOf: $0) }

        surface.emit([.selectPosition(.third), .stepEffort(1), .toggleFastMode])

        XCTAssertEqual(received, [.selectPosition(.third), .stepEffort(1), .toggleFastMode])
    }

    func testAgentTargetReceivesSettingsWithoutControllerKnowledge() {
        let target = FakeAgentTarget()
        let update = AgentSettingsUpdate(
            preset: ModelPreset(name: "Test", model: "model-id", effort: .high),
            fastMode: true
        )

        target.apply(update, to: "task-id") { _ in }

        XCTAssertEqual(target.lastTaskID, "task-id")
        XCTAssertEqual(target.lastUpdate, update)
    }
}

private final class FakeControlSurface: ControlSurface {
    let name = "Test controls"
    var onEvents: (([ControlSurfaceEvent]) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?

    func start() {}
    func stop() {}
    func emit(_ events: [ControlSurfaceEvent]) { onEvents?(events) }
}

private final class FakeAgentTarget: AgentTarget {
    private static let preset = ModelPreset(name: "Test", model: "model-id", effort: .high)
    let name = "Test agent"
    let controlIsExperimental = false
    let supportedPresets = [FakeAgentTarget.preset]
    let defaultTransmissionMap = TransmissionMap(
        forward: Array(repeating: FakeAgentTarget.preset, count: 6),
        reverse: FakeAgentTarget.preset
    )
    var onStateChanged: ((AgentTargetState) -> Void)?
    var onTasksChanged: (([AgentTask]) -> Void)?
    var onFocusedTaskChanged: ((String?) -> Void)?
    var lastTaskID: String?
    var lastUpdate: AgentSettingsUpdate?

    func start() {}
    func stop() {}
    func reconnect() {}
    func refreshTasks() {}
    func stepEffort(from preset: ModelPreset, direction: Int) -> ModelPreset { preset }
    func stepModelFamily(from preset: ModelPreset, direction: Int) -> ModelPreset { preset }
    func taskURL(for taskID: String) -> URL? { nil }

    func apply(
        _ update: AgentSettingsUpdate,
        to taskID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        lastUpdate = update
        lastTaskID = taskID
        completion(.success(()))
    }
}
