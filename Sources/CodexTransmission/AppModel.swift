import AppKit
import Foundation
import AgentTransmissionCore

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

    var controlSurfaceName: String { controlSurface.name }
    var agentTargetName: String { agentTarget.name }
    var agentTargetControlIsExperimental: Bool { agentTarget.controlIsExperimental }
    var supportedPresets: [ModelPreset] { agentTarget.supportedPresets }
    var isUsingDefaultMap: Bool { map == agentTarget.defaultTransmissionMap }

    var targetSelection: TargetSelection {
        if let pinnedID = defaults.string(forKey: "pinnedTaskID")
            ?? defaults.string(forKey: "pinnedThreadID") {
            return .pinned(pinnedID)
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
    private let agentTarget: any AgentTarget
    private var refreshTimer: Timer?
    private var modifierGestureConsumed = false
    private var modifierHoldWorkItem: DispatchWorkItem?

    init(
        controlSurface: any ControlSurface,
        agentTarget: any AgentTarget,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.controlSurface = controlSurface
        self.agentTarget = agentTarget
        fastMode = defaults.bool(forKey: Self.fastModeKey)
        if let data = defaults.data(forKey: Self.transmissionMapKey),
           let saved = try? JSONDecoder().decode(TransmissionMap.self, from: data),
           saved.isCompatible(with: agentTarget.supportedPresets) {
            map = saved
        } else {
            map = agentTarget.defaultTransmissionMap
        }
    }

    func start() {
        controlSurface.onConnectionChanged = { [weak self] connected in
            self?.controlSurfaceConnected = connected
            self?.publish()
        }
        controlSurface.onEvents = { [weak self] events in self?.handle(events) }

        agentTarget.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.targetDiscoveryConnected = state.discoveryConnected
            self.targetControlConnected = state.controlConnected
            if let message = state.message {
                self.status = message
            } else if state.discoveryConnected && state.controlConnected {
                self.status = self.parked ? "Parked" : "Ready"
            }
            self.publish()
        }
        agentTarget.onTasksChanged = { [weak self] tasks in
            guard let self else { return }
            self.tasks = tasks
            self.status = self.parked ? "Parked" : "Ready"
            self.publish()
        }
        agentTarget.onFocusedTaskChanged = { [weak self] taskID in
            guard let self else { return }
            self.focusedTaskID = taskID
            if taskID != nil, self.targetTask == nil { self.refreshTasks() }
            self.publish()
        }

        controlSurface.start()
        agentTarget.start()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshTasks()
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        modifierHoldWorkItem?.cancel()
        controlSurface.stop()
        agentTarget.stop()
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
        defaults.removeObject(forKey: "pinnedTaskID")
        defaults.removeObject(forKey: "pinnedThreadID")
        publish()
    }

    func pinTarget(_ taskID: String) {
        defaults.set(taskID, forKey: "pinnedTaskID")
        defaults.removeObject(forKey: "pinnedThreadID")
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
        persistMap()
        status = "Default transmission restored · shift to apply"
        publish()
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
        agentTarget.apply(
            .init(preset: preset, fastMode: fastMode),
            to: targetTask.id
        ) { [weak self] result in
            guard let self else { return }
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
        agentTarget.apply(.init(fastMode: fastMode), to: targetTask.id) { [weak self] result in
            guard let self else { return }
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
        defaults.set(data, forKey: Self.transmissionMapKey)
    }

    private func publish() { onChange?() }
}
