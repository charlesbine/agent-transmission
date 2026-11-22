import Foundation

public enum ControlSurfaceEvent: Equatable, Sendable {
    case selectPosition(GearPosition)
    case enteredNeutral
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
    var supportsRichControlActions: Bool { get }
    var catalogModels: [CatalogModelSummary] { get }
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

    func currentThreadState(for taskID: String) -> AgentThreadLiveState?
    func presetForEffortSlot(_ gearIndex: Int, on taskID: String, fallback: ModelPreset?) -> ModelPreset?
    func setInteractionMode(_ mode: AgentInteractionMode, for taskID: String, completion: @escaping (Result<Void, Error>) -> Void)
    func setRuntimeMode(_ mode: AgentRuntimeMode, for taskID: String, completion: @escaping (Result<Void, Error>) -> Void)
    func interruptRun(for taskID: String, completion: @escaping (Result<Void, Error>) -> Void)
    func settleTask(_ taskID: String, completion: @escaping (Result<Void, Error>) -> Void)
}

public enum AgentTargetActionError: LocalizedError, Equatable, Sendable {
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(message): message
        }
    }
}

public extension AgentTarget {
    var supportsRichControlActions: Bool { false }

    var catalogModels: [CatalogModelSummary] {
        var grouped: [String: (name: String, provider: String, efforts: [ReasoningEffort])] = [:]
        var order: [String] = []
        for preset in supportedPresets {
            let provider = preset.provider ?? name
            let key = "\(provider)::\(preset.model)"
            if var existing = grouped[key] {
                if !existing.efforts.contains(preset.effort) {
                    existing.efforts.append(preset.effort)
                    grouped[key] = existing
                }
            } else {
                grouped[key] = (preset.name, provider, [preset.effort])
                order.append(key)
            }
        }
        return order.enumerated().compactMap { idx, key in
            guard let entry = grouped[key] else { return nil }
            let slug = String(key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).last ?? "")
            return CatalogModelSummary(
                providerInstanceID: entry.provider,
                providerLabel: name,
                accentColorHex: "#10B981",
                slug: slug,
                displayName: entry.name,
                isFavorite: true,
                supportedEfforts: entry.efforts,
                defaultEffort: entry.efforts.contains(.high) ? .high : (entry.efforts.first ?? .medium),
                supportsFastMode: true,
                tierRank: idx
            )
        }
    }

    func currentThreadState(for taskID: String) -> AgentThreadLiveState? { nil }

    func presetForEffortSlot(_ gearIndex: Int, on taskID: String, fallback: ModelPreset?) -> ModelPreset? {
        guard (1...6).contains(gearIndex) else { return nil }
        let targetEffort = ReasoningEffort.allCases[gearIndex - 1]
        guard let base = fallback ?? supportedPresets.first else { return nil }
        let modelPresets = supportedPresets.filter { $0.model == base.model && $0.provider == base.provider }
        guard !modelPresets.isEmpty else { return base }
        if let exact = modelPresets.first(where: { $0.effort == targetEffort }) {
            return exact
        }
        let targetRank = gearIndex - 1
        return modelPresets.min { lhs, rhs in
            let r1 = ReasoningEffort.allCases.firstIndex(of: lhs.effort) ?? 0
            let r2 = ReasoningEffort.allCases.firstIndex(of: rhs.effort) ?? 0
            return abs(r1 - targetRank) < abs(r2 - targetRank)
        }
    }

    func setInteractionMode(_ mode: AgentInteractionMode, for taskID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(AgentTargetActionError.unsupported("\(name) does not expose Plan/Code mode switching")))
    }

    func setRuntimeMode(_ mode: AgentRuntimeMode, for taskID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(AgentTargetActionError.unsupported("\(name) does not expose runtime permission switching")))
    }

    func interruptRun(for taskID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(AgentTargetActionError.unsupported("\(name) does not expose live run interruption")))
    }

    func settleTask(_ taskID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(AgentTargetActionError.unsupported("\(name) does not expose settling threads")))
    }
}
