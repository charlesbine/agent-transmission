import Foundation

public enum ControlSurfaceEvent: Equatable, Sendable {
    case selectPosition(GearPosition)
    case stepEffort(Int)
    case stepModelFamily(Int)
    case modifierChanged(Bool)
    case toggleParking
    case toggleFastMode
}

public protocol ControlSurface: AnyObject {
    var name: String { get }
    var onEvents: (([ControlSurfaceEvent]) -> Void)? { get set }
    var onConnectionChanged: ((Bool) -> Void)? { get set }

    func start()
    func stop()
}

public struct AgentSettingsUpdate: Equatable, Sendable {
    public let preset: ModelPreset?
    public let fastMode: Bool?

    public init(preset: ModelPreset? = nil, fastMode: Bool? = nil) {
        self.preset = preset
        self.fastMode = fastMode
    }
}

public struct AgentTargetState: Equatable, Sendable {
    public let discoveryConnected: Bool
    public let controlConnected: Bool
    public let message: String?

    public init(discoveryConnected: Bool, controlConnected: Bool, message: String? = nil) {
        self.discoveryConnected = discoveryConnected
        self.controlConnected = controlConnected
        self.message = message
    }
}

public protocol AgentTarget: AnyObject {
    var name: String { get }
    var controlIsExperimental: Bool { get }
    var supportedPresets: [ModelPreset] { get }
    var defaultTransmissionMap: TransmissionMap { get }
    var onStateChanged: ((AgentTargetState) -> Void)? { get set }
    var onTasksChanged: (([AgentTask]) -> Void)? { get set }
    var onFocusedTaskChanged: ((String?) -> Void)? { get set }

    func start()
    func stop()
    func reconnect()
    func refreshTasks()
    func stepEffort(from preset: ModelPreset, direction: Int) -> ModelPreset
    func stepModelFamily(from preset: ModelPreset, direction: Int) -> ModelPreset
    func apply(_ update: AgentSettingsUpdate, to taskID: String, completion: @escaping (Result<Void, Error>) -> Void)
    func taskURL(for taskID: String) -> URL?
}
