import Foundation

public enum GearPosition: Int, CaseIterable, Codable, Sendable {
    case first = 1
    case second = 2
    case third = 3
    case fourth = 4
    case fifth = 5
    case sixth = 6
    case reverse = 7
    case sequentialUp = 8
    case sequentialDown = 9

    public var label: String {
        switch self {
        case .first: "1"
        case .second: "2"
        case .third: "3"
        case .fourth: "4"
        case .fifth: "5"
        case .sixth: "6"
        case .reverse: "R"
        case .sequentialUp: "S+"
        case .sequentialDown: "S−"
        }
    }

    public var directGearIndex: Int? {
        (1...6).contains(rawValue) ? rawValue : nil
    }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    public var shortLabel: String {
        switch self {
        case .low: "Low"
        case .medium: "Med"
        case .high: "High"
        case .xhigh: "XHigh"
        case .max: "Max"
        case .ultra: "Ultra"
        }
    }
}

public struct ModelPreset: Equatable, Codable, Sendable {
    public let name: String
    public let model: String
    public let effort: ReasoningEffort

    public init(name: String, model: String, effort: ReasoningEffort) {
        self.name = name
        self.model = model
        self.effort = effort
    }

    public var displayLabel: String { "\(name) · \(effort.shortLabel)" }
}

public struct TransmissionMap: Equatable, Codable, Sendable {
    public let forward: [ModelPreset]
    public let reverse: ModelPreset

    public init(forward: [ModelPreset], reverse: ModelPreset) {
        precondition(forward.count == 6, "A transmission needs exactly six forward presets")
        self.forward = forward
        self.reverse = reverse
    }

    public var isValid: Bool { forward.count == 6 }

    public func isCompatible(with presets: [ModelPreset]) -> Bool {
        isValid && (forward + [reverse]).allSatisfy { selected in
            presets.contains { supported in
                selected.model == supported.model && selected.effort == supported.effort
            }
        }
    }

    public func preset(for position: GearPosition) -> ModelPreset? {
        if let index = position.directGearIndex { return forward[index - 1] }
        if position == .reverse { return reverse }
        return nil
    }

}

public struct AgentTask: Equatable, Sendable {
    public let id: String
    public let title: String
    public let workspace: String
    public let updatedAt: Int

    public init(id: String, title: String, workspace: String, updatedAt: Int) {
        self.id = id
        self.title = title
        self.workspace = workspace
        self.updatedAt = updatedAt
    }
}

public enum TargetSelection: Equatable, Sendable {
    case automatic
    case pinned(String)

    public func resolve(in tasks: [AgentTask]) -> AgentTask? {
        switch self {
        case .automatic:
            tasks.max { $0.updatedAt < $1.updatedAt }
        case let .pinned(id):
            tasks.first { $0.id == id }
        }
    }
}
