import XCTest
@testable import AgentTransmission
@testable import AgentTransmissionCore

final class AppModelAdapterTests: XCTestCase {
    func testInjectedControlSurfaceDrivesInjectedAgentTarget() {
        let suiteName = "AppModelAdapterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let surface = AppModelFakeSurface()
        let target = AppModelFakeTarget()
        let model = AppModel(controlSurface: surface, agentTarget: target, defaults: defaults)

        model.start()
        surface.emit([.selectPosition(.second)])

        XCTAssertTrue(surface.started)
        XCTAssertTrue(target.started)
        XCTAssertEqual(target.lastTaskID, "focused-task")
        XCTAssertEqual(target.lastUpdate?.preset, target.defaultTransmissionMap.preset(for: .second))
        XCTAssertEqual(target.lastUpdate?.fastMode, false)

        model.stop()
        XCTAssertTrue(surface.stopped)
        XCTAssertTrue(target.stopped)
    }
}

private final class AppModelFakeSurface: ControlSurface {
    let name = "Test controls"
    var onEvents: (([ControlSurfaceEvent]) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    var started = false
    var stopped = false

    func start() {
        started = true
        onConnectionChanged?(true)
    }

    func stop() { stopped = true }
    func emit(_ events: [ControlSurfaceEvent]) { onEvents?(events) }
}

private final class AppModelFakeTarget: AgentTarget {
    private static let preset = ModelPreset(name: "Test", model: "model-id", effort: .high)
    let name = "Test agent"
    let controlIsExperimental = false
    let supportedPresets = [AppModelFakeTarget.preset]
    let defaultTransmissionMap = TransmissionMap(
        forward: Array(repeating: AppModelFakeTarget.preset, count: 6),
        reverse: AppModelFakeTarget.preset
    )
    var onStateChanged: ((AgentTargetState) -> Void)?
    var onTasksChanged: (([AgentTask]) -> Void)?
    var onFocusedTaskChanged: ((String?) -> Void)?
    var started = false
    var stopped = false
    var lastTaskID: String?
    var lastUpdate: AgentSettingsUpdate?

    func start() {
        started = true
        onStateChanged?(.init(discoveryConnected: true, controlConnected: true))
        onTasksChanged?([.init(id: "focused-task", title: "Focused", workspace: "test", updatedAt: 1)])
        onFocusedTaskChanged?("focused-task")
    }

    func stop() { stopped = true }
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
