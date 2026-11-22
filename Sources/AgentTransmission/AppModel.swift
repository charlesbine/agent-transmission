import AppKit
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

final class AppModel {
    private static let transmissionMapKey = "transmissionMap.v1"
    private static let fastModeKey = "fastMode.v1"
    private static let fastModeHoldDuration: TimeInterval = 2

    var onChange: (() -> Void)?

    private(set) var tasks: [AgentTask] = []
    private(set) var controlSurfaceConnected = false
    private(set) var targetDiscoveryConnected = false
    private(set) var targetControlConnected = false
    private(set) var focusedTaskID: String?
    private(set) var parked = false
    private(set) var modifierHeld = false
    private(set) var fastMode: Bool
    private(set) var lastGear: GearPosition?
    private(set) var currentPreset: ModelPreset?
    private(set) var status = "Starting…"
    private(set) var map: TransmissionMap
    private(set) var selectedTargetKind: AgentTargetKind?

    var availableTargetKinds: [AgentTargetKind] {
        targetFactory != nil ? AgentTargetKind.allCases : []
    }
    var controlSurfaceName: String { controlSurface.name }
    var agentTargetName: String { agentTarget.name }
    var agentTargetControlIsExperimental: Bool { agentTarget.controlIsExperimental }
    var supportedPresets: [ModelPreset] { agentTarget.supportedPresets }
    var isUsingDefaultMap: Bool { map == agentTarget.defaultTransmissionMap }

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
    private var isStarted = false
    private var refreshTimer: Timer?
    private var modifierGestureConsumed = false
    private var modifierHoldWorkItem: DispatchWorkItem?

    private var currentTransmissionMapKey: String {
        switch selectedTargetKind {
        case .t3Code: "\(Self.transmissionMapKey).t3-code"
        case .codexDesktop, nil: Self.transmissionMapKey
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
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.controlSurface = controlSurface
        self.agentTarget = agentTarget
        self.targetFactory = nil
        self.selectedTargetKind = nil
        fastMode = defaults.bool(forKey: Self.fastModeKey)
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
        defaults: UserDefaults = .standard
    ) {
        let initialTarget = targetFactory(initialTargetKind)
        self.defaults = defaults
        self.controlSurface = controlSurface
        self.agentTarget = initialTarget
        self.targetFactory = targetFactory
        self.selectedTargetKind = initialTargetKind
        fastMode = defaults.bool(forKey: Self.fastModeKey)
        let mapKey = initialTargetKind == .t3Code
            ? "\(Self.transmissionMapKey).t3-code"
            : Self.transmissionMapKey
        map = Self.loadMap(
            defaults: defaults,
            key: mapKey,
            target: initialTarget
        )
    }

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
        controlSurface.stop()
        agentTarget.stop()
    }

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
        currentPreset = nil
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

    func toggleParkingBrake() {
        parked.toggle()
        status = parked ? "Parked" : "Ready"
        publish()
    }

    func toggleFastMode() {
        fastMode.toggle()
        defaults.set(fastMode, forKey: Self.fastModeKey)
        applyFastMode()
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
        status = "Gear \(position.label) set to \(preset.displayLabel) · shift to apply"
        publish()
    }

    func restoreDefaultMap() {
        map = agentTarget.defaultTransmissionMap
        defaults.removeObject(forKey: currentTransmissionMapKey)
        status = "Default transmission restored · shift to apply"
        publish()
    }

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

    func openTarget() {
        guard let targetTask,
              let url = agentTarget.taskURL(for: targetTask.id) else { return }
        NSWorkspace.shared.open(url)
    }

    private func handle(_ events: [ControlSurfaceEvent]) {
        for event in events {
            switch event {
            case let .modifierChanged(pressed):
                handleModifierChanged(pressed)
            case let .selectPosition(position):
                consumeModifierGestureIfHeld()
                lastGear = position
                if let preset = map.preset(for: position) {
                    currentPreset = preset
                    apply(preset)
                }
            case let .stepEffort(direction):
                lastGear = direction > 0 ? .sequentialUp : .sequentialDown
                let preset = agentTarget.stepEffort(
                    from: currentPreset ?? map.forward[1],
                    direction: direction
                )
                currentPreset = preset
                apply(preset)
            case let .stepModelFamily(direction):
                consumeModifierGestureIfHeld()
                lastGear = direction > 0 ? .sequentialUp : .sequentialDown
                let preset = agentTarget.stepModelFamily(
                    from: currentPreset ?? map.forward[1],
                    direction: direction
                )
                currentPreset = preset
                apply(preset)
            case .toggleParking:
                toggleParkingBrake()
            case .toggleFastMode:
                toggleFastMode()
            }
        }
        publish()
    }

    private func apply(_ preset: ModelPreset) {
        guard !parked else {
            status = "Parked · \(preset.displayLabel) staged"
            return
        }
        guard let targetTask else {
            status = "No \(agentTarget.name) task available"
            return
        }

        status = "Shifting \(targetTask.title) to \(preset.displayLabel)…"
        publish()
        guard targetControlConnected else {
            status = "\(agentTarget.name) control disconnected"
            return
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
                self.status = error.localizedDescription
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
                self.toggleFastMode()
            }
            modifierHoldWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fastModeHoldDuration, execute: workItem)
            status = "Modifier held · release for parking brake · hold for Fast"
        } else {
            modifierHoldWorkItem?.cancel()
            modifierHoldWorkItem = nil
            let shouldToggleParking = modifierHeld && !modifierGestureConsumed
            modifierHeld = false
            modifierGestureConsumed = false
            if shouldToggleParking { toggleParkingBrake() }
        }
    }

    private func consumeModifierGestureIfHeld() {
        guard modifierHeld else { return }
        modifierGestureConsumed = true
        modifierHoldWorkItem?.cancel()
        modifierHoldWorkItem = nil
    }

    private func applyFastMode() {
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
            case let .failure(error):
                self.status = error.localizedDescription
            }
            self.publish()
        }
    }

    private func persistMap() {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: currentTransmissionMapKey)
    }

    private func publish() { onChange?() }
}
