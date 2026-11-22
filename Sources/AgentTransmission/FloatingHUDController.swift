import AppKit
import SwiftUI
import AgentTransmissionCore

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: Double
        if cleaned.count == 6 {
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        } else {
            r = 0.38; g = 0.65; b = 0.98
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

final class FloatingHUDState: ObservableObject {
    @Published var payload: ShiftHUDPayload?
    @Published var isVisible = false
}

final class FloatingHUDController {
    private let model: AppModel
    private let state = FloatingHUDState()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?

    init(model: AppModel) {
        self.model = model
        model.onHUDUpdate = { [weak self] payload in
            self?.present(payload)
        }
    }

    deinit {
        stopModifierMonitors()
        hideWorkItem?.cancel()
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let existing = panel { return existing }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 278),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hosting = NSHostingView(rootView: FloatingShiftHUDView(state: state))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func present(_ payload: ShiftHUDPayload) {
        let panel = ensurePanel()
        hideWorkItem?.cancel()

        state.payload = payload
        let targetWidth: CGFloat = payload.slots.isEmpty ? 460 : 696
        let targetHeight: CGFloat = payload.slots.isEmpty ? 104 : 306

        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let screen {
            let visible = screen.visibleFrame
            let clampedWidth = min(targetWidth, visible.width - 40)
            let x = visible.midX - clampedWidth / 2
            let y = visible.minY + 34
            panel.setFrame(NSRect(x: x, y: y, width: clampedWidth, height: targetHeight), display: true)
        }

        if !state.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            state.isVisible = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

        if payload.kind == .decision {
            startModifierMonitors()
        } else {
            stopModifierMonitors()
        }

        // Stay open indefinitely if `autoHideDelay == nil` ("Until back in gear")
        // OR while a modifier key / (P) is actively being held.
        if let delay = payload.autoHideDelay, !payload.modifierActive {
            let workItem = DispatchWorkItem { [weak self] in
                self?.dismiss()
            }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func dismiss() {
        stopModifierMonitors()
        guard let panel, state.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if panel.alphaValue <= 0.01 {
                panel.orderOut(nil)
                self.state.isVisible = false
            }
        })
    }

    private func startModifierMonitors() {
        guard globalFlagsMonitor == nil else { return }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let mods = ActiveKeyboardModifiers(
                shift: event.modifierFlags.contains(.shift),
                option: event.modifierFlags.contains(.option)
            )
            DispatchQueue.main.async {
                self?.model.updateLiveModifiers(mods)
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let mods = ActiveKeyboardModifiers(
                shift: event.modifierFlags.contains(.shift),
                option: event.modifierFlags.contains(.option)
            )
            self?.model.updateLiveModifiers(mods)
            return event
        }
    }

    private func stopModifierMonitors() {
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
    }
}

private struct FloatingShiftHUDView: View {
    @ObservedObject var state: FloatingHUDState

    var body: some View {
        Group {
            if let payload = state.payload {
                if payload.slots.isEmpty {
                    compactToast(payload)
                } else {
                    gateOverlay(payload)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
    }

    private func compactToast(_ payload: ShiftHUDPayload) -> some View {
        HStack(spacing: 12) {
            badgeView(for: payload)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(payload.headline)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if payload.isError, let threadTitle = payload.threadTitle, !threadTitle.isEmpty {
                        Text(threadTitle.uppercased())
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.42))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Text(payload.detail)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.72))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.055, green: 0.07, blue: 0.098).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            payload.isError ? Color.orange.opacity(0.6) : Color.white.opacity(0.14),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.6), radius: 20, y: 9)
        )
    }

    private func gateOverlay(_ payload: ShiftHUDPayload) -> some View {
        let activeGear: GearPosition? = {
            if case let .engaged(pos) = payload.kind { return pos }
            return nil
        }()
        let cleanReverse = payload.reverseLabel.replacingOccurrences(of: "R · ", with: "")
        let accent = layerAccent(payload.layer)

        return VStack(spacing: 12) {
            // Top bar
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(accent)
                        .frame(width: 8, height: 8)
                    Text(payload.layerSourceLabel.map { "\($0) · \(payload.layer.badgeLabel)" } ?? payload.layer.badgeLabel)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(accent)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(accent.opacity(0.15)))

                Text(payload.headline)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let threadTitle = payload.threadTitle {
                    Text(threadTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 230, alignment: .trailing)
                }
            }

            // Real Machined H-Gate Diagram
            HGateDiagramView(
                style: .hud,
                slots: payload.slots,
                reverseTitle: cleanReverse,
                reverseSubtitle: "Reverse",
                activeGear: activeGear,
                editingGear: nil,
                isNeutral: payload.kind == .decision,
                layerAccent: accent,
                onSelectSlot: nil
            )

            // Footer hints / current state (strictly single-line, never wraps)
            HStack(spacing: 12) {
                if payload.kind == .decision {
                    HStack(spacing: 10) {
                        Text("⇧ Effort")
                        Text("·").foregroundColor(Color.white.opacity(0.25))
                        Text("⌥ Modes")
                        Text("·").foregroundColor(Color.white.opacity(0.25))
                        Text("(P) Park / Hold Fast")
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text(payload.detail)
                        .foregroundColor(Color.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if payload.kind == .decision {
                    Text(payload.detail)
                        .foregroundColor(Color.white.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundColor(Color.white.opacity(0.48))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.052, green: 0.064, blue: 0.092).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.65), radius: 26, y: 12)
        )
    }

    private func badgeView(for payload: ShiftHUDPayload) -> some View {
        let (text, color): (String, Color) = {
            switch payload.kind {
            case .parked: return ("P", Color(hex: "#F59E0B"))
            case .error: return ("!", Color(hex: "#EF4444"))
            case let .action(badge): return (badge, Color(hex: "#38BDF8"))
            case let .engaged(pos): return (pos.label, Color(hex: "#10B981"))
            case .decision: return ("N", Color(hex: "#38BDF8"))
            }
        }()
        return Text(text)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(.black)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color))
    }

    private func layerAccent(_ layer: GearLayer) -> Color {
        switch layer {
        case .models: Color(hex: "#38BDF8")
        case .effort: Color(hex: "#A78BFA")
        case .permissions: Color(hex: "#F59E0B")
        case .custom: Color(hex: "#10B981")
        }
    }
}
