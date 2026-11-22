import AppKit
import SwiftUI
import AgentTransmissionCore

final class StatusMenuController: NSObject {
    private let model: AppModel
    private let launchAtLogin = LaunchAtLoginController()
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var clickOutsideMonitor: Any?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 396, height: 610)
        popover.contentViewController = NSHostingController(
            rootView: PopoverAppView(
                model: model,
                launchAtLogin: launchAtLogin,
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusBarClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        model.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    deinit {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
        }
    }

    private func refresh() {
        let gear: String
        if model.modifierHeld {
            gear = "P…"
        } else if model.parked {
            gear = "🅿"
        } else if model.inNeutral {
            gear = "N"
        } else {
            gear = model.lastGear?.label ?? "N"
        }

        let liveLabel: String
        if let preset = model.currentPreset {
            liveLabel = " · \(preset.name) \(preset.effort.shortLabel)"
        } else if let live = model.currentThreadState, !live.modelLabel.isEmpty {
            let eff = live.effort.map { " \($0.shortLabel)" } ?? ""
            liveLabel = " · \(live.modelLabel)\(eff)"
        } else {
            liveLabel = ""
        }

        let speed = model.fastMode ? " · ⚡︎" : ""
        statusItem.button?.title = "\(gear)\(liveLabel)\(speed)"
        statusItem.button?.toolTip = model.status
    }

    @objc private func handleStatusBarClick(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }

        if event.type == .rightMouseUp {
            showQuickContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            model.refreshTasks()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            startClickOutsideMonitor()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        stopClickOutsideMonitor()
    }

    private func startClickOutsideMonitor() {
        stopClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.closePopover()
        }
    }

    private func stopClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }

    private func showQuickContextMenu() {
        closePopover()
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Agent Transmission", action: #selector(openPopoverFromMenu), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let hudItem = NSMenuItem(title: "Preview Decision HUD", action: #selector(previewHUD), keyEquivalent: "")
        hudItem.target = self
        menu.addItem(hudItem)

        menu.addItem(.separator())

        let reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        let quitItem = NSMenuItem(title: "Quit Agent Transmission", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPopoverFromMenu() { togglePopover() }
    @objc private func previewHUD() { model.previewDecisionHUD() }
    @objc private func reconnect() { model.reconnect() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
