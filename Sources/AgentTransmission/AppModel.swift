import AppKit
import Combine
import Foundation
import AgentTransmissionCore

enum AgentTargetKind: String, CaseIterable, Equatable, Sendable {
    case t3Code = "t3-code"
    case codexDesktop = "codex-desktop"

    static let userDefaultsKey = "agentTargetKind.v1"

    var displayName: String {
        switch self {
        case .t3Code: "T3 Code"
        case .codexDesktop: "Codex Desktop"
        }
    }

    static func defaultKind(t3RuntimeExists: Bool) -> AgentTargetKind {
        t3RuntimeExists ? .t3Code : .codexDesktop
    }

    static func resolveInitial(
        defaults: UserDefaults = .standard,
        t3RuntimeExists: Bool = T3CodeClient.runtimeStateExists()
    ) -> AgentTargetKind {
        if let raw = defaults.string(forKey: userDefaultsKey),
           let saved = AgentTargetKind(rawValue: raw) {
            return saved
        }
        return defaultKind(t3RuntimeExists: t3RuntimeExists)
    }
}

struct ActiveKeyboardModifiers: Equatable, Sendable {
    var shift: Bool = false
    var option: Bool = false

    static func current() -> ActiveKeyboardModifiers {
        let flags = NSEvent.modifierFlags
        return ActiveKeyboardModifiers(
            shift: flags.contains(.shift),
            option: flags.contains(.option)
        )
    }
}

struct HUDGateSlot: Equatable, Identifiable, Sendable {
    let position: GearPosition
    let title: String
    let subtitle: String?
    let accentHex: String
    let isActive: Bool
    let isCurrentThreadValue: Bool

    var id: Int { position.rawValue }
}

enum ShiftHUDKind: Equatable, Sendable {
    case decision
    case engaged(GearPosition)
    case action(badge: String)
    case parkHolding(
        startedAt: Date,
        holdDuration: TimeInterval,
        tapLabel: String,
        holdLabel: String,
        chordLabel: String?
    )
    case parked
    case error
}

struct ShiftHUDPayload: Equatable, Sendable {
    let kind: ShiftHUDKind
    let layer: GearLayer
    let layerSourceLabel: String?
    let headline: String
    let detail: String
    let threadTitle: String?
    let slots: [HUDGateSlot]
    let reverseLabel: String
    let isError: Bool
    /// `nil` means stay open until back in gear (or manually dismissed).
    let autoHideDelay: TimeInterval?
    /// True while a modifier key or (P) is currently held so the HUD stays pinned.
    let modifierActive: Bool
    /// Timestamp when this HUD payload was emitted (drives countdown progress bars).
    let emittedAt: Date
}

final class AppModel: ObservableObject {
    private static let transmissionMapKey = "transmissionMap.v1"
    private static let bindingsKey = "transmissionBindings.v2"
    private static let fastModeKey = "fastMode.v1"
    private static let parkHoldDuration: TimeInterval = 1.2

    var onChange: (() -> Void)?
    var onHUDUpdate: ((ShiftHUDPayload) -> Void)?

    private(set) var tasks: [AgentTask] = []
    private(set) var controlSurfaceConnected = false
    private(set) var targetDiscoveryConnected = false
    private(set) var targetControlConnected = false
    private(set) var focusedTaskID: String?
    private(set) var parked = false
    private(set) var modifierHeld = false
    private(set) var inNeutral = false
    private(set) var armedOneShotLayer: GearLayer?
    private(set) var fastMode: Bool
    private(set) var lastGear: GearPosition?
    private(set) var currentPreset: ModelPreset?
    private(set) var status = "Starting…"
    private(set) var map: TransmissionMap
    private(set) var bindings: TransmissionBindings
    private(set) var selectedTargetKind: AgentTargetKind?
    private(set) var liveModifiers = ActiveKeyboardModifiers()

    var availableTargetKinds: [AgentTargetKind] {
        targetFactory != nil ? AgentTargetKind.allCases : []
    }
    var controlSurfaceName: String { controlSurface.name }
    var agentTargetName: String { agentTarget.name }
    var agentTargetControlIsExperimental: Bool { agentTarget.controlIsExperimental }
    var supportsRichControlActions: Bool { agentTarget.supportsRichControlActions }
    var supportedPresets: [ModelPreset] { agentTarget.supportedPresets }
    var catalogModels: [CatalogModelSummary] { agentTarget.catalogModels }
    var isUsingDefaultMap: Bool { map == agentTarget.defaultTransmissionMap }

    var currentThreadState: AgentThreadLiveState? {
        guard let targetTask else { return nil }
        return agentTarget.currentThreadState(for: targetTask.id)
    }

    var targetSelection: TargetSelection {
        if let pinnedID = defaults.string(forKey: currentPinnedTaskKey) {
            return .pinned(pinnedID)
        }
        if selectedTargetKind != .t3Code,
           let legacyPinnedID = defaults.string(forKey: "pinnedThreadID") {
            return .pinned(legacyPinnedID)
        }
        return .automatic
    }

    var targetTask: AgentTask? {
        switch targetSelection {
        case .automatic:
            guard let focusedTaskID else { return nil }
            return tasks.first { $0.id == focusedTaskID }
        case .pinned:
            return targetSelection.resolve(in: tasks)
        }
    }

    private let defaults: UserDefaults
    private let controlSurface: any ControlSurface
    private var agentTarget: any AgentTarget
    private let targetFactory: ((AgentTargetKind) -> any AgentTarget)?
    private let modifierProvider: () -> ActiveKeyboardModifiers
    private var isStarted = false
    private var refreshTimer: Timer?
    private var modifierGestureConsumed = false
    private var modifierHoldWorkItem: DispatchWorkItem?
    private var oneShotExpireWorkItem: DispatchWorkItem?
    private var lastCatalogSignature: String = ""

    private var currentTransmissionMapKey: String {
        switch selectedTargetKind {
        case .t3Code: "\(Self.transmissionMapKey).t3-code"
        case .codexDesktop, nil: Self.transmissionMapKey
        }
    }

    private var currentBindingsKey: String {
        switch selectedTargetKind {
        case .t3Code: "\(Self.bindingsKey).t3-code"
        case .codexDesktop, nil: "\(Self.bindingsKey).codex"
        }
    }

    private var currentPinnedTaskKey: String {
        switch selectedTargetKind {
        case .t3Code: "pinnedTaskID.t3-code"
        case .codexDesktop, nil: "pinnedTaskID"
        }
    }

    init(
        controlSurface: any ControlSurface,
        agentTarget: any AgentTarget,
        defaults: UserDefaults = .standard,
        modifierProvider: @escaping () -> ActiveKeyboardModifiers = { .current() }
    ) {
        self.defaults = defaults
        self.controlSurface = controlSurface
        self.agentTarget = agentTarget
        self.targetFactory = nil
        self.selectedTargetKind = nil
        self.modifierProvider = modifierProvider
        fastMode = defaults.bool(forKey: Self.fastModeKey)
        bindings = Self.loadBindings(
            defaults: defaults,
            key: "\(Self.bindingsKey).codex",
            fallback: .codexDefault
        )
        map = Self.loadMap(
            defaults: defaults,
            key: Self.transmissionMapKey,
            target: agentTarget
        )
    }

    init(
        controlSurface: any ControlSurface,
        initialTargetKind: AgentTargetKind,
        targetFactory: @escaping (AgentTargetKind) -> any AgentTarget,
        defaults: UserDefaults = .standard,
        modifierProvider: @escaping () -> ActiveKeyboardModifiers = { .current() }
    ) {
        let initialTarget = targetFactory(initialTargetKind)
        self.defaults = defaults
        self.controlSurface = controlSurface
        self.agentTarget = initialTarget
        self.targetFactory = targetFactory
        self.selectedTargetKind = initialTargetKind
        self.modifierProvider = modifierProvider
        fastMode = defaults.bool(forKey: Self.fastModeKey)
        let bindingsKey = initialTargetKind == .t3Code ? "\(Self.bindingsKey).t3-code" : "\(Self.bindingsKey).codex"
        bindings = Self.loadBindings(
            defaults: defaults,
            key: bindingsKey,
            fallback: initialTargetKind == .t3Code ? .t3Default : .codexDefault
        )
        let mapKey = initialTargetKind == .t3Code
            ? "\(Self.transmissionMapKey).t3-code"
            : Self.transmissionMapKey
        map = Self.loadMap(
            defaults: defaults,
            key: mapKey,
            target: initialTarget
        )
    }

    // MARK: - Lifecycle

    func start() {
        isStarted = true
        controlSurface.onConnectionChanged = { [weak self] connected in
            self?.controlSurfaceConnected = connected
            self?.publish()
        }
        controlSurface.onEvents = { [weak self] events in self?.handle(events) }

        wireAgentTargetCallbacks(agentTarget)

        controlSurface.start()
        agentTarget.start()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshTasks()
        }
    }

    func stop() {
        isStarted = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        modifierHoldWorkItem?.cancel()
        oneShotExpireWorkItem?.cancel()
        controlSurface.stop()
        agentTarget.stop()
    }

    // MARK: - Target & Task Management

    func selectAgentTarget(_ kind: AgentTargetKind) {
        guard let targetFactory, selectedTargetKind != kind else { return }
        defaults.set(kind.rawValue, forKey: AgentTargetKind.userDefaultsKey)

        let previousTarget = agentTarget
        previousTarget.onStateChanged = nil
        previousTarget.onTasksChanged = nil
        previousTarget.onFocusedTaskChanged = nil
        previousTarget.stop()

        selectedTargetKind = kind
        let nextTarget = targetFactory(kind)
        agentTarget = nextTarget

        tasks = []
        focusedTaskID = nil
        targetDiscoveryConnected = false
        targetControlConnected = false
        lastGear = nil
        inNeutral = false
        currentPreset = nil
        lastCatalogSignature = ""
        bindings = Self.loadBindings(
            defaults: defaults,
            key: currentBindingsKey,
            fallback: kind == .t3Code ? .t3Default : .codexDefault
        )
        map = Self.loadMap(
            defaults: defaults,
            key: currentTransmissionMapKey,
            target: nextTarget
        )
        status = parked ? "Parked" : "Connecting to \(nextTarget.name)…"

        if isStarted {
            wireAgentTargetCallbacks(nextTarget)
            nextTarget.start()
        }
        publish()
    }

    func reconnect() {
        status = "Reconnecting to \(agentTarget.name)…"
        publish()
        agentTarget.reconnect()
    }

    func refreshTasks() {
        agentTarget.refreshTasks()
    }

    func selectAutomaticTarget() {
        defaults.removeObject(forKey: currentPinnedTaskKey)
        if selectedTargetKind != .t3Code {
            defaults.removeObject(forKey: "pinnedThreadID")
        }
        publish()
    }

    func pinTarget(_ taskID: String) {
        defaults.set(taskID, forKey: currentPinnedTaskKey)
        if selectedTargetKind != .t3Code {
            defaults.removeObject(forKey: "pinnedThreadID")
        }
        publish()
    }

    func openTarget() {
        guard let targetTask,
              let url = agentTarget.taskURL(for: targetTask.id) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Gearbox Configuration & Smart Presets

    func updateBindings(_ mutate: (inout TransmissionBindings) -> Void) {
        mutate(&bindings)
        persistBindings()
        if bindings.autoSyncFavorites {
            syncFromFavorites(silent: true)
        }
        publish()
    }

    func configure(_ position: GearPosition, preset: ModelPreset) {
        if let index = position.directGearIndex {
            var forward = map.forward
            forward[index - 1] = preset
            map = TransmissionMap(forward: forward, reverse: map.reverse)
        } else if position == .reverse {
            map = TransmissionMap(forward: map.forward, reverse: preset)
        } else {
            return
        }
        persistMap()
        status = "Gear \(position.label) → \(preset.displayLabel) · shift to apply"
        publish()
    }

    func syncFromFavorites(silent: Bool = false) {
        let models = catalogModels
        let favorites = models.filter(\.isFavorite)
        let pool = favorites.isEmpty ? models : favorites
        guard !pool.isEmpty else { return }

        var forward: [ModelPreset] = []
        if pool.count >= 6 {
            forward = pool.prefix(6).map { $0.preset() }
        } else {
            // Distribute 6 slots evenly across available favorites.
            let count = pool.count
            let base = 6 / count
            let extra = 6 % count
            for (idx, model) in pool.enumerated() {
                let slots = base + (idx < extra ? 1 : 0)
                if slots == 1 {
                    forward.append(model.preset())
                } else {
                    let efforts = model.supportedEfforts
                    for step in 0..<slots {
                        let ratio = Double(step) / Double(max(slots - 1, 1))
                        let eIdx = Int(round(ratio * Double(max(efforts.count - 1, 0))))
                        let eff = efforts.indices.contains(eIdx) ? efforts[eIdx] : model.defaultEffort
                        forward.append(model.preset(effort: eff))
                    }
                }
            }
        }

        let reviewModel = pool[0]
        let reviewEffort: ReasoningEffort = reviewModel.supportedEfforts.contains(.max)
            ? .max
            : (reviewModel.supportedEfforts.last ?? reviewModel.defaultEffort)
        map = TransmissionMap(forward: forward, reverse: reviewModel.preset(effort: reviewEffort))
        persistMap()
        if !silent {
            status = "Synced 6 gears from ★ Favorites"
            publish()
        }
    }

    func sortGears(fastToSmart: Bool) {
        let lookup = Dictionary(uniqueKeysWithValues: catalogModels.map { ("\($0.providerInstanceID)::\($0.slug)", $0) })
        let effortOrder = ReasoningEffort.allCases

        let sorted = map.forward.sorted { lhs, rhs in
            let rankL = lookup["\(lhs.provider ?? "")::\(lhs.model)"]?.tierRank
                ?? T3CodeAgentTarget.modelTierRank(slug: lhs.model, displayName: lhs.name)
            let rankR = lookup["\(rhs.provider ?? "")::\(rhs.model)"]?.tierRank
                ?? T3CodeAgentTarget.modelTierRank(slug: rhs.model, displayName: rhs.name)
            if rankL != rankR {
                return fastToSmart ? rankL < rankR : rankL > rankR
            }
            let eL = effortOrder.firstIndex(of: lhs.effort) ?? 0
            let eR = effortOrder.firstIndex(of: rhs.effort) ?? 0
            if eL != eR {
                return fastToSmart ? eL < eR : eL > eR
            }
            return lhs.name < rhs.name
        }

        map = TransmissionMap(forward: sorted, reverse: map.reverse)
        persistMap()
        status = fastToSmart ? "Sorted 1 → 6: Fast → Smart" : "Sorted 1 → 6: Smart → Fast"
        publish()
    }

    func restoreDefaultMap() {
        map = agentTarget.defaultTransmissionMap
        defaults.removeObject(forKey: currentTransmissionMapKey)
        bindings = selectedTargetKind == .t3Code ? .t3Default : .codexDefault
        defaults.removeObject(forKey: currentBindingsKey)
        status = "Defaults restored · shift to apply"
        publish()
    }

    // MARK: - Live Layer & HUD Helpers

    func resolveActiveLayer(modifiers: ActiveKeyboardModifiers? = nil) -> (layer: GearLayer, source: String?) {
        let mods = modifiers ?? liveModifiers
        if mods.shift, bindings.shiftModifierLayer != .disabled {
            return (gearLayer(from: bindings.shiftModifierLayer), "⇧ SHIFT")
        }
        if mods.option, bindings.optionModifierLayer != .disabled {
            return (gearLayer(from: bindings.optionModifierLayer), "⌥ OPTION")
        }
        if modifierHeld, bindings.parkChordLayer != .disabled {
            return (gearLayer(from: bindings.parkChordLayer), "(P) HOLD")
        }
        if let armedOneShotLayer {
            return (armedOneShotLayer, "ONE-SHOT")
        }
        switch bindings.gearboxMode {
        case .models:
            return (.models, nil)
        case .effort:
            return (.effort, nil)
        case .custom:
            return (.custom, nil)
        }
    }

    func armOneShotLayer(_ layer: GearLayer) {
        if armedOneShotLayer == layer {
            disarmOneShotLayer(showCancelledToast: true)
            return
        }
        oneShotExpireWorkItem?.cancel()
        armedOneShotLayer = layer
        let duration = bindings.neutralHUDTimeout.duration ?? 8.0
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.armedOneShotLayer == layer else { return }
            self.armedOneShotLayer = nil
            self.oneShotExpireWorkItem = nil
            self.status = "Ready"
            self.publish()
        }
        oneShotExpireWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
        status = "One-shot \(layer.badgeLabel.lowercased()) armed · throw next gear"
        emitDecisionHUD(
            force: true,
            overrideTimeout: duration,
            headlineOverride: layer == .effort ? "Next Shift → Effort" : "Next Shift → T3 Modes"
        )
        publish()
    }

    func disarmOneShotLayer(showCancelledToast: Bool = false) {
        guard armedOneShotLayer != nil else { return }
        oneShotExpireWorkItem?.cancel()
        oneShotExpireWorkItem = nil
        armedOneShotLayer = nil
        status = parked ? "Parked" : "Ready"
        if showCancelledToast {
            emitActionHUD(kind: .action(badge: "CANCEL"), headline: "One-Shot Cancelled", detail: "Back to \(bindings.gearboxMode.displayLabel) mode")
        }
        publish()
    }

    private func gearLayer(from action: ModifierLayerAction) -> GearLayer {
        switch action {
        case .effort: .effort
        case .models: .models
        case .permissions: .permissions
        case .disabled:
            switch bindings.gearboxMode {
            case .models: .models
            case .effort: .effort
            case .custom: .custom
            }
        }
    }

    func updateLiveModifiers(_ modifiers: ActiveKeyboardModifiers) {
        guard modifiers != liveModifiers else { return }
        liveModifiers = modifiers
        if (inNeutral || armedOneShotLayer != nil) && bindings.showFloatingHUD {
            emitDecisionHUD()
        }
        publish()
    }

    func previewDecisionHUD() {
        liveModifiers = modifierProvider()
        emitDecisionHUD(force: true, overrideTimeout: 5.0)
    }

    func hudSlots(for layer: GearLayer, highlighted: GearPosition? = nil) -> [HUDGateSlot] {
        let live = currentThreadState
        let catalogByKey = Dictionary(uniqueKeysWithValues: catalogModels.map { ("\($0.providerInstanceID)::\($0.slug)", $0) })

        return (1...6).map { index in
            let pos = GearPosition(rawValue: index)!
            switch layer {
            case .models, .custom:
                let preset = map.forward[index - 1]
                let summary = catalogByKey["\(preset.provider ?? "")::\(preset.model)"]
                    ?? catalogModels.first(where: { $0.slug == preset.model })
                let accent = summary?.accentColorHex ?? "#60A5FA"
                let modelMatches = live?.modelSlug == preset.model
                    && (preset.provider == nil || live?.providerInstanceID == preset.provider)
                let isCurrent = layer == .custom
                    ? (modelMatches && live?.effort == preset.effort)
                    : modelMatches
                let sub = layer == .custom
                    ? preset.effort.shortLabel
                    : (summary?.providerLabel ?? preset.effort.shortLabel)
                let cleanTitle: String = {
                    if let providerLabel = summary?.providerLabel,
                       preset.name.hasSuffix(" (\(providerLabel))") {
                        return String(preset.name.dropLast(" (\(providerLabel))".count))
                    }
                    return preset.name
                }()
                return HUDGateSlot(
                    position: pos,
                    title: cleanTitle,
                    subtitle: sub,
                    accentHex: accent,
                    isActive: highlighted == pos,
                    isCurrentThreadValue: isCurrent
                )

            case .effort:
                let effort = ReasoningEffort.allCases[index - 1]
                let activeModel = live.flatMap { state in
                    catalogModels.first(where: { $0.slug == state.modelSlug && ($0.providerInstanceID == state.providerInstanceID || state.providerInstanceID == nil) })
                }
                let supported = activeModel?.supportedEfforts.contains(effort) ?? true
                let isCurrent = live?.effort == effort
                return HUDGateSlot(
                    position: pos,
                    title: effort.shortLabel,
                    subtitle: supported ? (isCurrent ? "Active" : "Reasoning") : "Clamps",
                    accentHex: supported ? "#38BDF8" : "#64748B",
                    isActive: highlighted == pos,
                    isCurrentThreadValue: isCurrent
                )

            case .permissions:
                switch index {
                case 1:
                    return HUDGateSlot(position: pos, title: "Ask", subtitle: "Approval", accentHex: "#F59E0B", isActive: highlighted == pos, isCurrentThreadValue: live?.runtimeMode == .approvalRequired)
                case 2:
                    return HUDGateSlot(position: pos, title: "Edits", subtitle: "Auto-accept", accentHex: "#38BDF8", isActive: highlighted == pos, isCurrentThreadValue: live?.runtimeMode == .autoAcceptEdits)
                case 3:
                    return HUDGateSlot(position: pos, title: "Auto", subtitle: "Standard", accentHex: "#10B981", isActive: highlighted == pos, isCurrentThreadValue: live?.runtimeMode == .auto)
                case 4:
                    return HUDGateSlot(position: pos, title: "Full", subtitle: "Full access", accentHex: "#EF4444", isActive: highlighted == pos, isCurrentThreadValue: live?.runtimeMode == .fullAccess)
                case 5:
                    return HUDGateSlot(position: pos, title: "Plan", subtitle: "Plan mode", accentHex: "#A78BFA", isActive: highlighted == pos, isCurrentThreadValue: live?.interactionMode == .plan)
                default:
                    return HUDGateSlot(position: pos, title: "Code", subtitle: "Default", accentHex: "#2DD4BF", isActive: highlighted == pos, isCurrentThreadValue: live?.interactionMode == .defaultMode)
                }
            }
        }
    }

    func reverseSlotLabel() -> String {
        switch bindings.reverseAction {
        case .togglePlanMode:
            let next = currentThreadState?.interactionMode == .plan ? "→ Code" : "→ Plan"
            return "R · \(next)"
        case .interruptRun:
            return "R · Interrupt"
        case .reviewPreset, .seventhGear:
            return "R · \(map.reverse.name)"
        case .toggleFastMode:
            return "R · Fast"
        case .settleThread:
            return "R · Settle"
        }
    }

    // MARK: - Direct Actions (Popover & Hardware)

    func toggleParkingBrake() {
        parked.toggle()
        status = parked ? "Parked" : "Ready"
        emitActionHUD(
            kind: parked ? .parked : .action(badge: "READY"),
            headline: parked ? "Parking Brake Engaged" : "Parking Brake Released",
            detail: parked ? "Gear shifts locked out" : "Ready to shift"
        )
        publish()
    }

    func toggleFastMode(fromGear: GearPosition? = nil) {
        fastMode.toggle()
        defaults.set(fastMode, forKey: Self.fastModeKey)
        applyFastMode(fromGear: fromGear)
    }

    func togglePlanMode(fromGear: GearPosition? = nil) {
        guard let targetTask else {
            status = "No \(agentTarget.name) task available"
            publish()
            return
        }
        let currentlyPlan = currentThreadState?.interactionMode == .plan
        let next: AgentInteractionMode = currentlyPlan ? .defaultMode : .plan
        setInteractionMode(next, on: targetTask, fromGear: fromGear)
    }

    func setInteractionMode(
        _ mode: AgentInteractionMode,
        on task: AgentTask? = nil,
        fromGear: GearPosition? = nil,
        layer: GearLayer? = nil,
        source: String? = nil
    ) {
        guard let task = task ?? targetTask else {
            status = "No \(agentTarget.name) task available"
            publish()
            return
        }
        guard targetControlConnected else {
            status = "\(agentTarget.name) control disconnected"
            publish()
            return
        }
        status = "Setting \(task.title) to \(mode.displayLabel) mode…"
        publish()
        let activeTarget = agentTarget
        activeTarget.setInteractionMode(mode, for: task.id) { [weak self, weak activeTarget] result in
            guard let self, let activeTarget, self.agentTarget === activeTarget else { return }
            switch result {
            case .success:
                self.status = "\(task.title) · \(mode.displayLabel) mode"
                let hudKind: ShiftHUDKind = fromGear.map { .engaged($0) } ?? .action(badge: mode == .plan ? "PLAN" : "CODE")
                let headline = fromGear.map { "[\($0.label)] \(mode.displayLabel) Mode" } ?? "\(mode.displayLabel) Mode"
                self.emitActionHUD(
                    kind: hudKind,
                    headline: headline,
                    detail: task.title,
                    layerOverride: layer,
                    sourceOverride: source ?? (fromGear == .reverse ? "REVERSE" : nil)
                )
            case let .failure(error):
                self.status = error.localizedDescription
                self.emitErrorHUD(headline: "Mode Switch Failed", detail: error.localizedDescription)
            }
            self.publish()
        }
    }

    func setRuntimeMode(
        _ mode: AgentRuntimeMode,
        on task: AgentTask? = nil,
        fromGear: GearPosition? = nil,
        layer: GearLayer? = nil,
        source: String? = nil
    ) {
        guard let task = task ?? targetTask else {
            status = "No \(agentTarget.name) task available"
            publish()
            return
        }
        guard targetControlConnected else {
            status = "\(agentTarget.name) control disconnected"
            publish()
            return
        }
        status = "Setting \(task.title) to \(mode.displayLabel)…"
        publish()
        let activeTarget = agentTarget
        activeTarget.setRuntimeMode(mode, for: task.id) { [weak self, weak activeTarget] result in
            guard let self, let activeTarget, self.agentTarget === activeTarget else { return }
            switch result {
            case .success:
                self.status = "\(task.title) · \(mode.displayLabel)"
                let hudKind: ShiftHUDKind = fromGear.map { .engaged($0) } ?? .action(badge: mode.shortLabel.uppercased())
                let headline = fromGear.map { "[\($0.label)] Permission → \(mode.displayLabel)" } ?? "Permission → \(mode.displayLabel)"
                self.emitActionHUD(
                    kind: hudKind,
                    headline: headline,
                    detail: task.title,
                    layerOverride: layer,
                    sourceOverride: source
                )
            case let .failure(error):
                self.status = error.localizedDescription
                self.emitErrorHUD(headline: "Permission Update Failed", detail: error.localizedDescription)
            }
            self.publish()
        }
    }

    func interruptActiveRun(fromGear: GearPosition? = nil) {
        guard let targetTask else {
            status = "No \(agentTarget.name) task available"
            publish()
            return
        }
        let activeTarget = agentTarget
        activeTarget.interruptRun(for: targetTask.id) { [weak self, weak activeTarget] result in
            guard let self, let activeTarget, self.agentTarget === activeTarget else { return }
            switch result {
            case .success:
                self.status = "Interrupted \(targetTask.title)"
                let hudKind: ShiftHUDKind = fromGear.map { .engaged($0) } ?? .action(badge: "STOP")
                let headline = fromGear.map { "[\($0.label)] Run Interrupted" } ?? "Run Interrupted"
                self.emitActionHUD(
                    kind: hudKind,
                    headline: headline,
                    detail: targetTask.title,
                    sourceOverride: fromGear == .reverse ? "REVERSE" : nil
                )
            case let .failure(error):
                self.status = error.localizedDescription
                self.emitErrorHUD(headline: "Interrupt", detail: error.localizedDescription)
            }
            self.publish()
        }
    }

    func settleCurrentTask(fromGear: GearPosition? = nil) {
        guard let targetTask else {
            status = "No \(agentTarget.name) task available"
            publish()
            return
        }
        let activeTarget = agentTarget
        activeTarget.settleTask(targetTask.id) { [weak self, weak activeTarget] result in
            guard let self, let activeTarget, self.agentTarget === activeTarget else { return }
            switch result {
            case .success:
                self.status = "Settled \(targetTask.title)"
                let hudKind: ShiftHUDKind = fromGear.map { .engaged($0) } ?? .action(badge: "SETTLED")
                let headline = fromGear.map { "[\($0.label)] Thread Settled" } ?? "Thread Settled"
                self.emitActionHUD(
                    kind: hudKind,
                    headline: headline,
                    detail: targetTask.title,
                    sourceOverride: fromGear == .reverse ? "REVERSE" : nil
                )
            case let .failure(error):
                self.status = error.localizedDescription
                self.emitErrorHUD(headline: "Settle Failed", detail: error.localizedDescription)
            }
            self.publish()
        }
    }

    // MARK: - Target Callbacks

    private func wireAgentTargetCallbacks(_ target: any AgentTarget) {
        target.onStateChanged = { [weak self, weak target] state in
            guard let self, let target, self.agentTarget === target else { return }
            self.targetDiscoveryConnected = state.discoveryConnected
            self.targetControlConnected = state.controlConnected
            self.syncMapWithCurrentTargetPresets()
            if let message = state.message {
                self.status = message
            } else if state.discoveryConnected && state.controlConnected {
                self.status = self.parked ? "Parked" : "Ready"
            }
            self.publish()
        }
        target.onTasksChanged = { [weak self, weak target] tasks in
            guard let self, let target, self.agentTarget === target else { return }
            self.tasks = tasks
            if self.parked {
                self.status = "Parked"
            } else if self.status == "Starting…"
                || self.status.hasPrefix("Connecting")
                || self.status.hasPrefix("Reconnecting")
                || self.status.hasPrefix("No ") {
                self.status = "Ready"
            }
            self.publish()
        }
        target.onFocusedTaskChanged = { [weak self, weak target] taskID in
            guard let self, let target, self.agentTarget === target else { return }
            self.focusedTaskID = taskID
            if taskID != nil, self.targetTask == nil { self.refreshTasks() }
            self.publish()
        }
    }

    private func syncMapWithCurrentTargetPresets() {
        let favSig = catalogModels.filter(\.isFavorite).map(\.id).joined(separator: ",")
        if bindings.autoSyncFavorites && !favSig.isEmpty && favSig != lastCatalogSignature {
            lastCatalogSignature = favSig
            syncFromFavorites(silent: true)
            return
        }
        lastCatalogSignature = favSig

        if let data = defaults.data(forKey: currentTransmissionMapKey),
           let saved = try? JSONDecoder().decode(TransmissionMap.self, from: data),
           saved.isCompatible(with: agentTarget.supportedPresets) {
            map = saved
        } else {
            map = agentTarget.defaultTransmissionMap
        }
    }

    private static func loadMap(
        defaults: UserDefaults,
        key: String,
        target: any AgentTarget
    ) -> TransmissionMap {
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(TransmissionMap.self, from: data),
           saved.isCompatible(with: target.supportedPresets) {
            return saved
        }
        return target.defaultTransmissionMap
    }

    private static func loadBindings(
        defaults: UserDefaults,
        key: String,
        fallback: TransmissionBindings
    ) -> TransmissionBindings {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(TransmissionBindings.self, from: data) {
            return decoded
        }
        return fallback
    }

    // MARK: - Hardware Event Handling

    private func handle(_ events: [ControlSurfaceEvent]) {
        liveModifiers = modifierProvider()
        for event in events {
            switch event {
            case let .modifierChanged(pressed):
                handleModifierChanged(pressed)
            case .enteredNeutral:
                inNeutral = true
                if !parked && bindings.showFloatingHUD && bindings.showHUDOnNeutral {
                    emitDecisionHUD()
                }
            case let .selectPosition(position):
                let wasParkChord = modifierHeld
                consumeModifierGestureIfHeld()
                inNeutral = false
                lastGear = position
                handleDirectPosition(position, parkChord: wasParkChord)
            case let .stepEffort(direction):
                inNeutral = false
                lastGear = direction > 0 ? .sequentialUp : .sequentialDown
                handleSequential(direction: direction, modifiedByPark: false)
            case let .stepModelFamily(direction):
                consumeModifierGestureIfHeld()
                inNeutral = false
                lastGear = direction > 0 ? .sequentialUp : .sequentialDown
                handleSequential(direction: direction, modifiedByPark: true)
            case .toggleParking:
                executeParkAction(bindings.parkTapAction)
            case .toggleFastMode:
                executeParkAction(bindings.parkHoldAction)
            }
        }
        publish()
    }

    private func handleDirectPosition(_ position: GearPosition, parkChord: Bool) {
        if parked {
            status = "Parked · gear \(position.label) ignored"
            emitActionHUD(kind: .parked, headline: "Parked", detail: "Release (P) to shift")
            return
        }

        if position == .reverse {
            executeReverseAction()
            return
        }

        guard let gearIndex = position.directGearIndex else { return }

        // Resolve active layer (keyboard modifiers > (P) chord > armed one-shot > gearboxMode)
        let consumedOneShot = armedOneShotLayer
        if consumedOneShot != nil {
            oneShotExpireWorkItem?.cancel()
            oneShotExpireWorkItem = nil
            armedOneShotLayer = nil
        }

        let resolved: (layer: GearLayer, source: String?)
        if liveModifiers.shift && bindings.shiftModifierLayer != .disabled {
            resolved = (gearLayer(from: bindings.shiftModifierLayer), "⇧ SHIFT")
        } else if liveModifiers.option && bindings.optionModifierLayer != .disabled {
            resolved = (gearLayer(from: bindings.optionModifierLayer), "⌥ OPTION")
        } else if parkChord && bindings.parkChordLayer != .disabled {
            resolved = (gearLayer(from: bindings.parkChordLayer), "(P) HOLD")
        } else if let consumedOneShot {
            resolved = (consumedOneShot, "ONE-SHOT")
        } else {
            switch bindings.gearboxMode {
            case .models: resolved = (.models, nil)
            case .effort: resolved = (.effort, nil)
            case .custom: resolved = (.custom, nil)
            }
        }

        switch resolved.layer {
        case .models, .custom:
            if let preset = map.preset(for: position) {
                currentPreset = preset
                apply(preset, position: position, layer: resolved.layer, source: resolved.source)
            }

        case .effort:
            guard let targetTask else {
                status = "No \(agentTarget.name) task available"
                return
            }
            if let preset = agentTarget.presetForEffortSlot(gearIndex, on: targetTask.id, fallback: currentPreset ?? map.forward[gearIndex - 1]) {
                currentPreset = preset
                apply(preset, position: position, layer: .effort, source: resolved.source)
            }

        case .permissions:
            switch gearIndex {
            case 1: setRuntimeMode(.approvalRequired, fromGear: position, layer: .permissions, source: resolved.source)
            case 2: setRuntimeMode(.autoAcceptEdits, fromGear: position, layer: .permissions, source: resolved.source)
            case 3: setRuntimeMode(.auto, fromGear: position, layer: .permissions, source: resolved.source)
            case 4: setRuntimeMode(.fullAccess, fromGear: position, layer: .permissions, source: resolved.source)
            case 5: setInteractionMode(.plan, fromGear: position, layer: .permissions, source: resolved.source)
            case 6: setInteractionMode(.defaultMode, fromGear: position, layer: .permissions, source: resolved.source)
            default: break
            }
        }
    }

    private func executeReverseAction() {
        switch bindings.reverseAction {
        case .togglePlanMode:
            togglePlanMode(fromGear: .reverse)
        case .interruptRun:
            interruptActiveRun(fromGear: .reverse)
        case .reviewPreset, .seventhGear:
            let preset = map.reverse
            currentPreset = preset
            apply(preset, position: .reverse, layer: .custom, source: "REVERSE")
        case .toggleFastMode:
            toggleFastMode(fromGear: .reverse)
        case .settleThread:
            settleCurrentTask(fromGear: .reverse)
        }
    }

    private func executeParkAction(_ action: ParkButtonAction) {
        switch action {
        case .oneShotEffort:
            armOneShotLayer(.effort)
        case .oneShotPermissions:
            armOneShotLayer(.permissions)
        case .parkingBrake:
            toggleParkingBrake()
        case .toggleFastMode:
            toggleFastMode()
        case .togglePlanMode:
            togglePlanMode()
        case .interruptRun:
            interruptActiveRun()
        case .settleThread:
            settleCurrentTask()
        case .disabled:
            break
        }
    }

    private func handleSequential(direction: Int, modifiedByPark: Bool) {
        if parked {
            status = "Parked · sequential ignored"
            emitActionHUD(kind: .parked, headline: "Parked", detail: "Release (P) to shift")
            return
        }

        let basePreset = currentLivePreset() ?? currentPreset ?? map.forward[1]
        if modifiedByPark {
            let preset = agentTarget.stepModelFamily(from: basePreset, direction: direction)
            currentPreset = preset
            apply(preset, position: direction > 0 ? .sequentialUp : .sequentialDown, layer: .models, source: "SEQUENTIAL")
            return
        }

        switch bindings.sequentialAction {
        case .stepEffort:
            let preset = agentTarget.stepEffort(from: basePreset, direction: direction)
            currentPreset = preset
            apply(preset, position: direction > 0 ? .sequentialUp : .sequentialDown, layer: .effort, source: "SEQUENTIAL")
        case .stepModels:
            let preset = agentTarget.stepModelFamily(from: basePreset, direction: direction)
            currentPreset = preset
            apply(preset, position: direction > 0 ? .sequentialUp : .sequentialDown, layer: .models, source: "SEQUENTIAL")
        case .stepRuntimeMode:
            let modes = AgentRuntimeMode.allCases
            let current = currentThreadState?.runtimeMode ?? .auto
            let idx = modes.firstIndex(of: current) ?? 2
            let nextIdx = min(max(idx + (direction > 0 ? 1 : -1), 0), modes.count - 1)
            setRuntimeMode(modes[nextIdx])
        case .disabled:
            break
        }
    }

    private func currentLivePreset() -> ModelPreset? {
        guard let live = currentThreadState, !live.modelSlug.isEmpty else { return nil }
        return ModelPreset(
            name: live.modelLabel,
            model: live.modelSlug,
            effort: live.effort ?? .medium,
            provider: live.providerInstanceID
        )
    }

    private func apply(
        _ preset: ModelPreset,
        position: GearPosition? = nil,
        layer: GearLayer = .models,
        source: String? = nil
    ) {
        guard !parked else {
            status = "Parked · \(preset.displayLabel) staged"
            return
        }
        guard let targetTask else {
            status = "No \(agentTarget.name) task available"
            emitErrorHUD(headline: "No Active Task", detail: "Focus a thread in \(agentTarget.name)")
            return
        }

        status = "Shifting \(targetTask.title) to \(preset.displayLabel)…"
        publish()
        guard targetControlConnected else {
            status = "\(agentTarget.name) control disconnected"
            emitErrorHUD(headline: "\(agentTarget.name) Disconnected", detail: "Check connection and retry")
            return
        }

        if let position, bindings.showFloatingHUD {
            emitEngagedHUD(position: position, preset: preset, layer: layer, source: source, task: targetTask)
        }

        let activeTarget = agentTarget
        activeTarget.apply(
            .init(preset: preset, fastMode: fastMode),
            to: targetTask.id
        ) { [weak self, weak activeTarget] result in
            guard let self, let activeTarget, self.agentTarget === activeTarget else { return }
            switch result {
            case .success:
                self.status = "\(targetTask.title) · \(preset.displayLabel) · \(self.fastMode ? "Fast" : "Standard")"
            case let .failure(error):
                let presented = ShiftErrorPresenter.present(error)
                self.status = "\(presented.headline) — \(presented.detail)"
                self.emitErrorHUD(headline: presented.headline, detail: presented.detail)
            }
            self.publish()
        }
    }

    private func handleModifierChanged(_ pressed: Bool) {
        if pressed {
            guard !modifierHeld else { return }
            modifierHeld = true
            modifierGestureConsumed = false
            modifierHoldWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.modifierHeld, !self.modifierGestureConsumed else { return }
                self.modifierGestureConsumed = true
                self.executeParkAction(self.bindings.parkHoldAction)
            }
            modifierHoldWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.parkHoldDuration, execute: workItem)
            status = "(P) held · release: \(bindings.parkTapAction.shortLabel) · hold: \(bindings.parkHoldAction.shortLabel)"
            emitParkHoldHUD()
        } else {
            modifierHoldWorkItem?.cancel()
            modifierHoldWorkItem = nil
            let shouldTap = modifierHeld && !modifierGestureConsumed
            modifierHeld = false
            modifierGestureConsumed = false
            if shouldTap {
                executeParkAction(bindings.parkTapAction)
            } else if inNeutral && bindings.showFloatingHUD && bindings.showHUDOnNeutral {
                emitDecisionHUD()
            }
        }
    }

    private func consumeModifierGestureIfHeld() {
        guard modifierHeld else { return }
        modifierGestureConsumed = true
        modifierHoldWorkItem?.cancel()
        modifierHoldWorkItem = nil
    }

    private func applyFastMode(fromGear: GearPosition? = nil) {
        let label = fastMode ? "Fast" : "Standard"
        guard !parked else {
            status = "Parked · \(label) staged"
            publish()
            return
        }
        guard let targetTask else {
            status = "No \(agentTarget.name) task available · \(label) staged"
            publish()
            return
        }
        guard targetControlConnected else {
            status = "\(agentTarget.name) control disconnected"
            publish()
            return
        }

        status = "Setting \(targetTask.title) to \(label)…"
        publish()
        let activeTarget = agentTarget
        activeTarget.apply(.init(fastMode: fastMode), to: targetTask.id) { [weak self, weak activeTarget] result in
            guard let self, let activeTarget, self.agentTarget === activeTarget else { return }
            switch result {
            case .success:
                self.status = "\(targetTask.title) · \(label)"
                let hudKind: ShiftHUDKind = fromGear.map { .engaged($0) } ?? .action(badge: self.fastMode ? "⚡ FAST" : "STD")
                let headline = fromGear.map { "[\($0.label)] Fast Mode \(self.fastMode ? "On" : "Off")" } ?? "Fast Mode \(self.fastMode ? "On" : "Off")"
                self.emitActionHUD(
                    kind: hudKind,
                    headline: headline,
                    detail: targetTask.title,
                    sourceOverride: fromGear == .reverse ? "REVERSE" : nil
                )
            case let .failure(error):
                self.status = error.localizedDescription
                self.emitErrorHUD(headline: "Fast Mode", detail: error.localizedDescription)
            }
            self.publish()
        }
    }

    // MARK: - HUD Payload Builders

    private var hasAnyActiveModifier: Bool {
        liveModifiers.shift || liveModifiers.option || modifierHeld
    }

    private func emitParkHoldHUD() {
        guard bindings.showFloatingHUD else { return }
        let resolved = resolveActiveLayer()
        let chordText: String? = bindings.parkChordLayer == .disabled
            ? nil
            : "(P) + Gear 1–6 → \(bindings.parkChordLayer.displayLabel)"
        let now = Date()
        let payload = ShiftHUDPayload(
            kind: .parkHolding(
                startedAt: now,
                holdDuration: Self.parkHoldDuration,
                tapLabel: bindings.parkTapAction.shortLabel,
                holdLabel: bindings.parkHoldAction.shortLabel,
                chordLabel: chordText
            ),
            layer: resolved.layer,
            layerSourceLabel: "(P) SWITCH",
            headline: "Release or Keep Holding (P)",
            detail: targetTask?.title ?? agentTarget.name,
            threadTitle: targetTask?.title,
            slots: [],
            reverseLabel: reverseSlotLabel(),
            isError: false,
            autoHideDelay: nil,
            modifierActive: true,
            emittedAt: now
        )
        onHUDUpdate?(payload)
    }

    private func emitDecisionHUD(
        force: Bool = false,
        overrideTimeout: TimeInterval? = nil,
        headlineOverride: String? = nil
    ) {
        guard force || bindings.showFloatingHUD else { return }
        let resolved = resolveActiveLayer()
        let live = currentThreadState
        let currentSummary = live.map { "\($0.modelLabel)\($0.effort.map { " · \($0.shortLabel)" } ?? "") · \($0.interactionMode.displayLabel)" }
            ?? "Select a gear"
        let timeout: TimeInterval? = overrideTimeout ?? bindings.neutralHUDTimeout.duration
        let headline: String = headlineOverride
            ?? (armedOneShotLayer != nil ? "Next Shift → \(resolved.layer.badgeLabel.capitalized)" : "Neutral · Choose Gear")
        let payload = ShiftHUDPayload(
            kind: .decision,
            layer: resolved.layer,
            layerSourceLabel: resolved.source,
            headline: headline,
            detail: currentSummary,
            threadTitle: targetTask?.title,
            slots: hudSlots(for: resolved.layer, highlighted: nil),
            reverseLabel: reverseSlotLabel(),
            isError: false,
            autoHideDelay: timeout,
            modifierActive: hasAnyActiveModifier,
            emittedAt: Date()
        )
        onHUDUpdate?(payload)
    }

    private func emitEngagedHUD(
        position: GearPosition,
        preset: ModelPreset,
        layer: GearLayer,
        source: String?,
        task: AgentTask
    ) {
        guard bindings.showFloatingHUD else { return }
        let modeHint = currentThreadState.map { "\($0.interactionMode.displayLabel) · \($0.runtimeMode.shortLabel)" } ?? ""
        let payload = ShiftHUDPayload(
            kind: .engaged(position),
            layer: layer,
            layerSourceLabel: source,
            headline: "[\(position.label)] \(preset.displayLabel)",
            detail: modeHint.isEmpty ? task.title : "\(preset.effort.shortLabel) · \(modeHint)",
            threadTitle: task.title,
            slots: hudSlots(for: layer, highlighted: position),
            reverseLabel: reverseSlotLabel(),
            isError: false,
            autoHideDelay: bindings.engagedHUDTimeout.duration,
            modifierActive: false,
            emittedAt: Date()
        )
        onHUDUpdate?(payload)
    }

    private func emitActionHUD(
        kind: ShiftHUDKind,
        headline: String,
        detail: String,
        layerOverride: GearLayer? = nil,
        sourceOverride: String? = nil
    ) {
        guard bindings.showFloatingHUD else { return }
        let resolved = resolveActiveLayer()
        let activeLayer = layerOverride ?? resolved.layer
        let highlighted: GearPosition? = {
            if case let .engaged(pos) = kind { return pos }
            return nil
        }()
        let payload = ShiftHUDPayload(
            kind: kind,
            layer: activeLayer,
            layerSourceLabel: sourceOverride ?? resolved.source,
            headline: headline,
            detail: detail,
            threadTitle: targetTask?.title,
            slots: hudSlots(for: activeLayer, highlighted: highlighted),
            reverseLabel: reverseSlotLabel(),
            isError: false,
            autoHideDelay: bindings.engagedHUDTimeout.duration,
            modifierActive: false,
            emittedAt: Date()
        )
        onHUDUpdate?(payload)
    }

    private func emitErrorHUD(headline: String, detail: String) {
        guard bindings.showFloatingHUD else { return }
        let resolved = resolveActiveLayer()
        let payload = ShiftHUDPayload(
            kind: .error,
            layer: resolved.layer,
            layerSourceLabel: nil,
            headline: headline,
            detail: detail,
            threadTitle: targetTask?.title,
            slots: [],
            reverseLabel: reverseSlotLabel(),
            isError: true,
            autoHideDelay: 4.0,
            modifierActive: false,
            emittedAt: Date()
        )
        onHUDUpdate?(payload)
    }

    // MARK: - Persistence

    private func persistMap() {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: currentTransmissionMapKey)
    }

    private func persistBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: currentBindingsKey)
    }

    private func publish() {
        objectWillChange.send()
        onChange?()
    }
}
