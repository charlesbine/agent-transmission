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
    public let provider: String?

    public init(name: String, model: String, effort: ReasoningEffort, provider: String? = nil) {
        self.name = name
        self.model = model
        self.effort = effort
        self.provider = provider
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
                selected.model == supported.model
                    && selected.effort == supported.effort
                    && selected.provider == supported.provider
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

public enum AgentInteractionMode: String, Codable, CaseIterable, Sendable {
    case defaultMode = "default"
    case plan = "plan"

    public var displayLabel: String {
        switch self {
        case .defaultMode: "Code"
        case .plan: "Plan"
        }
    }
}

public enum AgentRuntimeMode: String, Codable, CaseIterable, Sendable {
    case approvalRequired = "approval-required"
    case autoAcceptEdits = "auto-accept-edits"
    case auto = "auto"
    case fullAccess = "full-access"

    public var shortLabel: String {
        switch self {
        case .approvalRequired: "Ask"
        case .autoAcceptEdits: "Edits"
        case .auto: "Auto"
        case .fullAccess: "Full"
        }
    }

    public var displayLabel: String {
        switch self {
        case .approvalRequired: "Ask Approval"
        case .autoAcceptEdits: "Auto Edits"
        case .auto: "Auto"
        case .fullAccess: "Full Access"
        }
    }
}

public struct AgentThreadLiveState: Equatable, Sendable {
    public let threadID: String
    public let modelSlug: String
    public let providerInstanceID: String?
    public let modelLabel: String
    public let effort: ReasoningEffort?
    public let fastMode: Bool?
    public let interactionMode: AgentInteractionMode
    public let runtimeMode: AgentRuntimeMode
    public let isRunning: Bool

    public init(
        threadID: String,
        modelSlug: String,
        providerInstanceID: String? = nil,
        modelLabel: String,
        effort: ReasoningEffort? = nil,
        fastMode: Bool? = nil,
        interactionMode: AgentInteractionMode = .defaultMode,
        runtimeMode: AgentRuntimeMode = .auto,
        isRunning: Bool = false
    ) {
        self.threadID = threadID
        self.modelSlug = modelSlug
        self.providerInstanceID = providerInstanceID
        self.modelLabel = modelLabel
        self.effort = effort
        self.fastMode = fastMode
        self.interactionMode = interactionMode
        self.runtimeMode = runtimeMode
        self.isRunning = isRunning
    }
}

public struct CatalogModelSummary: Equatable, Identifiable, Sendable {
    public let id: String
    public let providerInstanceID: String
    public let providerLabel: String
    public let accentColorHex: String
    public let slug: String
    public let displayName: String
    public let isFavorite: Bool
    public let supportedEfforts: [ReasoningEffort]
    public let defaultEffort: ReasoningEffort
    public let supportsFastMode: Bool
    public let tierRank: Int

    public init(
        providerInstanceID: String,
        providerLabel: String,
        accentColorHex: String,
        slug: String,
        displayName: String,
        isFavorite: Bool,
        supportedEfforts: [ReasoningEffort],
        defaultEffort: ReasoningEffort,
        supportsFastMode: Bool,
        tierRank: Int
    ) {
        self.id = "\(providerInstanceID)::\(slug)"
        self.providerInstanceID = providerInstanceID
        self.providerLabel = providerLabel
        self.accentColorHex = accentColorHex
        self.slug = slug
        self.displayName = displayName
        self.isFavorite = isFavorite
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
        self.supportsFastMode = supportsFastMode
        self.tierRank = tierRank
    }

    public func preset(effort: ReasoningEffort? = nil) -> ModelPreset {
        let resolvedEffort = effort.flatMap { supportedEfforts.contains($0) ? $0 : nil } ?? defaultEffort
        return ModelPreset(
            name: displayName,
            model: slug,
            effort: resolvedEffort,
            provider: providerInstanceID
        )
    }
}

public enum GearboxMode: String, Codable, CaseIterable, Sendable {
    case models
    case effort
    case custom

    public var displayLabel: String {
        switch self {
        case .models: "Models"
        case .effort: "Effort"
        case .custom: "Custom"
        }
    }

    public var subtitle: String {
        switch self {
        case .models: "1–6 switch models · ⇧/S change effort"
        case .effort: "1–6 change effort · ⇧/S switch models"
        case .custom: "1–6 apply exact model + effort presets"
        }
    }
}

public enum GearLayer: String, Codable, CaseIterable, Sendable {
    case models
    case effort
    case permissions
    case custom

    public var badgeLabel: String {
        switch self {
        case .models: "MODELS"
        case .effort: "EFFORT"
        case .permissions: "MODES"
        case .custom: "CUSTOM"
        }
    }
}

public enum ModifierLayerAction: String, Codable, CaseIterable, Sendable {
    case disabled
    case effort
    case models
    case permissions

    public var displayLabel: String {
        switch self {
        case .disabled: "Disabled"
        case .effort: "Effort (1=Low → 6=Ultra)"
        case .models: "Model Slots (1–6)"
        case .permissions: "T3 Modes (Permissions & Plan)"
        }
    }
}

public enum ReverseGearAction: String, Codable, CaseIterable, Sendable {
    case togglePlanMode
    case interruptRun
    case reviewPreset
    case seventhGear
    case toggleFastMode
    case settleThread

    public var displayLabel: String {
        switch self {
        case .togglePlanMode: "Toggle Plan ↔ Code"
        case .interruptRun: "Interrupt Active Run"
        case .reviewPreset: "Review Preset (R Slot)"
        case .seventhGear: "7th Gear Slot"
        case .toggleFastMode: "Toggle Fast Mode"
        case .settleThread: "Settle Thread"
        }
    }

    public var shortLabel: String {
        switch self {
        case .togglePlanMode: "Plan/Code"
        case .interruptRun: "Interrupt"
        case .reviewPreset: "Review"
        case .seventhGear: "Slot R"
        case .toggleFastMode: "Fast Mode"
        case .settleThread: "Settle"
        }
    }
}

public enum ParkButtonAction: String, Codable, CaseIterable, Sendable {
    case oneShotEffort
    case oneShotPermissions
    case parkingBrake
    case toggleFastMode
    case togglePlanMode
    case interruptRun
    case settleThread
    case disabled

    public var displayLabel: String {
        switch self {
        case .oneShotEffort: "One-Shot Effort (next shift)"
        case .oneShotPermissions: "One-Shot T3 Modes (next shift)"
        case .parkingBrake: "Software Parking Brake"
        case .toggleFastMode: "Toggle Fast Mode"
        case .togglePlanMode: "Toggle Plan ↔ Code"
        case .interruptRun: "Interrupt Active Run"
        case .settleThread: "Settle Thread"
        case .disabled: "Disabled"
        }
    }

    public var shortLabel: String {
        switch self {
        case .oneShotEffort: "One-Shot Effort"
        case .oneShotPermissions: "One-Shot Modes"
        case .parkingBrake: "Parking Brake"
        case .toggleFastMode: "Fast Mode"
        case .togglePlanMode: "Plan ↔ Code"
        case .interruptRun: "Interrupt Run"
        case .settleThread: "Settle Thread"
        case .disabled: "Disabled"
        }
    }
}

public enum SequentialPaddleAction: String, Codable, CaseIterable, Sendable {
    case stepEffort
    case stepModels
    case stepRuntimeMode
    case disabled

    public var displayLabel: String {
        switch self {
        case .stepEffort: "Step Effort (Low ↔ Ultra)"
        case .stepModels: "Step Favorite Models"
        case .stepRuntimeMode: "Step Permission Mode (Ask ↔ Full)"
        case .disabled: "Disabled"
        }
    }
}

public enum NeutralHUDTimeout: String, Codable, CaseIterable, Sendable {
    case seconds4
    case seconds8
    case seconds15
    case untilInGear

    public var displayLabel: String {
        switch self {
        case .seconds4: "4 seconds"
        case .seconds8: "8 seconds"
        case .seconds15: "15 seconds"
        case .untilInGear: "Until back in gear"
        }
    }

    public var duration: TimeInterval? {
        switch self {
        case .seconds4: 4.0
        case .seconds8: 8.0
        case .seconds15: 15.0
        case .untilInGear: nil
        }
    }
}

public enum EngagedHUDTimeout: String, Codable, CaseIterable, Sendable {
    case fast
    case normal
    case long

    public var displayLabel: String {
        switch self {
        case .fast: "1.0s"
        case .normal: "1.5s"
        case .long: "2.5s"
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .fast: 1.0
        case .normal: 1.5
        case .long: 2.5
        }
    }
}

public struct TransmissionBindings: Codable, Equatable, Sendable {
    public var gearboxMode: GearboxMode
    public var reverseAction: ReverseGearAction
    public var parkTapAction: ParkButtonAction
    public var parkHoldAction: ParkButtonAction
    public var parkChordLayer: ModifierLayerAction
    public var shiftModifierLayer: ModifierLayerAction
    public var optionModifierLayer: ModifierLayerAction
    public var sequentialAction: SequentialPaddleAction
    public var showFloatingHUD: Bool
    public var showHUDOnNeutral: Bool
    public var neutralHUDTimeout: NeutralHUDTimeout
    public var engagedHUDTimeout: EngagedHUDTimeout
    public var autoSyncFavorites: Bool

    public init(
        gearboxMode: GearboxMode = .models,
        reverseAction: ReverseGearAction = .togglePlanMode,
        parkTapAction: ParkButtonAction = .parkingBrake,
        parkHoldAction: ParkButtonAction = .toggleFastMode,
        parkChordLayer: ModifierLayerAction = .effort,
        shiftModifierLayer: ModifierLayerAction = .effort,
        optionModifierLayer: ModifierLayerAction = .permissions,
        sequentialAction: SequentialPaddleAction = .stepEffort,
        showFloatingHUD: Bool = true,
        showHUDOnNeutral: Bool = true,
        neutralHUDTimeout: NeutralHUDTimeout = .seconds8,
        engagedHUDTimeout: EngagedHUDTimeout = .normal,
        autoSyncFavorites: Bool = false
    ) {
        self.gearboxMode = gearboxMode
        self.reverseAction = reverseAction
        self.parkTapAction = parkTapAction
        self.parkHoldAction = parkHoldAction
        self.parkChordLayer = parkChordLayer
        self.shiftModifierLayer = shiftModifierLayer
        self.optionModifierLayer = optionModifierLayer
        self.sequentialAction = sequentialAction
        self.showFloatingHUD = showFloatingHUD
        self.showHUDOnNeutral = showHUDOnNeutral
        self.neutralHUDTimeout = neutralHUDTimeout
        self.engagedHUDTimeout = engagedHUDTimeout
        self.autoSyncFavorites = autoSyncFavorites
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gearboxMode = (try? c.decodeIfPresent(GearboxMode.self, forKey: .gearboxMode)) ?? .models
        reverseAction = (try? c.decodeIfPresent(ReverseGearAction.self, forKey: .reverseAction)) ?? .togglePlanMode
        parkTapAction = (try? c.decodeIfPresent(ParkButtonAction.self, forKey: .parkTapAction)) ?? .parkingBrake
        parkHoldAction = (try? c.decodeIfPresent(ParkButtonAction.self, forKey: .parkHoldAction)) ?? .toggleFastMode
        parkChordLayer = (try? c.decodeIfPresent(ModifierLayerAction.self, forKey: .parkChordLayer)) ?? .effort
        shiftModifierLayer = (try? c.decodeIfPresent(ModifierLayerAction.self, forKey: .shiftModifierLayer)) ?? .effort
        optionModifierLayer = (try? c.decodeIfPresent(ModifierLayerAction.self, forKey: .optionModifierLayer)) ?? .permissions
        sequentialAction = (try? c.decodeIfPresent(SequentialPaddleAction.self, forKey: .sequentialAction)) ?? .stepEffort
        showFloatingHUD = (try? c.decodeIfPresent(Bool.self, forKey: .showFloatingHUD)) ?? true
        showHUDOnNeutral = (try? c.decodeIfPresent(Bool.self, forKey: .showHUDOnNeutral)) ?? true
        neutralHUDTimeout = (try? c.decodeIfPresent(NeutralHUDTimeout.self, forKey: .neutralHUDTimeout)) ?? .seconds8
        engagedHUDTimeout = (try? c.decodeIfPresent(EngagedHUDTimeout.self, forKey: .engagedHUDTimeout)) ?? .normal
        autoSyncFavorites = (try? c.decodeIfPresent(Bool.self, forKey: .autoSyncFavorites)) ?? false
    }

    public static let t3Default = TransmissionBindings(
        gearboxMode: .models,
        reverseAction: .togglePlanMode,
        parkTapAction: .oneShotEffort,
        parkHoldAction: .toggleFastMode,
        parkChordLayer: .effort,
        shiftModifierLayer: .effort,
        optionModifierLayer: .permissions,
        sequentialAction: .stepEffort,
        showFloatingHUD: true,
        showHUDOnNeutral: true,
        autoSyncFavorites: false
    )

    public static let codexDefault = TransmissionBindings(
        gearboxMode: .custom,
        reverseAction: .reviewPreset,
        parkTapAction: .parkingBrake,
        parkHoldAction: .toggleFastMode,
        parkChordLayer: .effort,
        shiftModifierLayer: .effort,
        optionModifierLayer: .disabled,
        sequentialAction: .stepEffort,
        showFloatingHUD: true,
        showHUDOnNeutral: true,
        autoSyncFavorites: false
    )
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
