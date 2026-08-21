import AppKit
import AgentTransmissionCore

private final class PresetMenuChoice: NSObject {
    let position: GearPosition
    let preset: ModelPreset

    init(position: GearPosition, preset: ModelPreset) {
        self.position = position
        self.preset = preset
    }
}

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.menu = menu
        menu.delegate = self
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.refreshTasks()
        rebuildMenu()
    }

    private func refresh() {
        let gear = model.modifierHeld ? "P…" : (model.parked ? "P" : (model.lastGear?.label ?? "N"))
        let preset = model.currentPreset.map { " · \($0.name) \($0.effort.shortLabel)" } ?? ""
        let speed = model.fastMode ? " · ⚡︎" : ""
        statusItem.button?.title = "\(gear)\(preset)\(speed)"
        statusItem.button?.toolTip = model.status
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let status = NSMenuItem(title: model.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let hardware = NSMenuItem(
            title: model.controlSurfaceConnected
                ? "\(model.controlSurfaceName) connected"
                : "\(model.controlSurfaceName) disconnected",
            action: nil,
            keyEquivalent: ""
        )
        hardware.isEnabled = false
        menu.addItem(hardware)
        let discovery = NSMenuItem(
            title: model.targetDiscoveryConnected
                ? "\(model.agentTargetName) task discovery connected"
                : "\(model.agentTargetName) task discovery disconnected",
            action: nil,
            keyEquivalent: ""
        )
        discovery.isEnabled = false
        menu.addItem(discovery)
        let experimental = model.agentTargetControlIsExperimental ? " · experimental" : ""
        let control = NSMenuItem(
            title: model.targetControlConnected
                ? "\(model.agentTargetName) control connected\(experimental)"
                : "\(model.agentTargetName) control disconnected\(experimental)",
            action: nil,
            keyEquivalent: ""
        )
        control.isEnabled = false
        menu.addItem(control)
        menu.addItem(.separator())

        let park = NSMenuItem(
            title: model.parked ? "Release parking brake" : "Apply parking brake",
            action: #selector(toggleParkingBrake),
            keyEquivalent: "p"
        )
        park.target = self
        menu.addItem(park)

        let fast = NSMenuItem(
            title: "Fast mode · \(model.fastMode ? "On" : "Off")",
            action: #selector(toggleFastMode),
            keyEquivalent: "f"
        )
        fast.target = self
        fast.state = model.fastMode ? .on : .off
        menu.addItem(fast)

        let target = NSMenuItem(title: targetTitle, action: nil, keyEquivalent: "")
        target.submenu = targetMenu()
        menu.addItem(target)

        let open = NSMenuItem(title: "Open target task", action: #selector(openTarget), keyEquivalent: "o")
        open.target = self
        open.isEnabled = model.targetTask != nil
        menu.addItem(open)

        menu.addItem(.separator())
        let mappingHeader = NSMenuItem(title: "Transmission · configure", action: nil, keyEquivalent: "")
        mappingHeader.isEnabled = false
        menu.addItem(mappingHeader)
        for (index, preset) in model.map.forward.enumerated() {
            let position = GearPosition(rawValue: index + 1)!
            let item = NSMenuItem(title: "  \(position.label)  \(preset.displayLabel)", action: nil, keyEquivalent: "")
            item.submenu = presetMenu(for: position, current: preset)
            menu.addItem(item)
        }
        let reverse = model.map.reverse
        let reverseItem = NSMenuItem(title: "  R  \(reverse.displayLabel)", action: nil, keyEquivalent: "")
        reverseItem.submenu = presetMenu(for: .reverse, current: reverse)
        menu.addItem(reverseItem)
        let restore = NSMenuItem(title: "Restore transmission defaults", action: #selector(restoreDefaults), keyEquivalent: "")
        restore.target = self
        restore.isEnabled = !model.isUsingDefaultMap
        menu.addItem(restore)

        menu.addItem(.separator())
        let reconnect = NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r")
        reconnect.target = self
        menu.addItem(reconnect)
        let quit = NSMenuItem(title: "Quit Codex Transmission", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private var targetTitle: String {
        guard let task = model.targetTask else { return "Target · none" }
        let mode = model.targetSelection == .automatic ? "Auto" : "Pinned"
        return "Target · \(mode) · \(task.title)"
    }

    private func targetMenu() -> NSMenu {
        let submenu = NSMenu()
        let automatic = NSMenuItem(
            title: "Auto · focused \(model.agentTargetName) task",
            action: #selector(selectAutomatic),
            keyEquivalent: ""
        )
        automatic.target = self
        automatic.state = model.targetSelection == .automatic ? .on : .off
        submenu.addItem(automatic)
        submenu.addItem(.separator())

        for task in model.tasks.prefix(12) {
            let item = NSMenuItem(
                title: "\(task.title) — \(task.workspace)",
                action: #selector(selectTask(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = task.id
            item.state = model.targetSelection == .pinned(task.id) ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private func presetMenu(for position: GearPosition, current: ModelPreset) -> NSMenu {
        let submenu = NSMenu()
        var previousName: String?
        for preset in model.supportedPresets {
            if let previousName, previousName != preset.name { submenu.addItem(.separator()) }
            previousName = preset.name
            let item = NSMenuItem(title: preset.displayLabel, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = PresetMenuChoice(position: position, preset: preset)
            item.state = preset == current ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func toggleParkingBrake() { model.toggleParkingBrake() }
    @objc private func toggleFastMode() { model.toggleFastMode() }
    @objc private func selectAutomatic() { model.selectAutomaticTarget() }
    @objc private func openTarget() { model.openTarget() }
    @objc private func reconnect() { model.reconnect() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func restoreDefaults() { model.restoreDefaultMap() }

    @objc private func selectTask(_ sender: NSMenuItem) {
        guard let taskID = sender.representedObject as? String else { return }
        model.pinTarget(taskID)
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? PresetMenuChoice else { return }
        model.configure(choice.position, preset: choice.preset)
    }
}
