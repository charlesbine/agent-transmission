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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 190),
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
        let targetWidth: CGFloat = payload.slots.isEmpty ? 340 : 540
        let targetHeight: CGFloat = payload.slots.isEmpty ? 92 : 216

        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let screen {
            let visible = screen.visibleFrame
            let x = visible.midX - targetWidth / 2
            let y = visible.minY + 28
            panel.setFrame(NSRect(x: x, y: y, width: targetWidth, height: targetHeight), display: true)
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

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + payload.autoHideDelay, execute: workItem)
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
        .padding(8)
    }

    private func compactToast(_ payload: ShiftHUDPayload) -> some View {
        HStack(spacing: 12) {
            badgeView(for: payload)
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.headline)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(payload.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.06, green: 0.075, blue: 0.105).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            payload.isError ? Color.orange.opacity(0.55) : Color.white.opacity(0.14),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
        )
    }

    private func gateOverlay(_ payload: ShiftHUDPayload) -> some View {
        let topSlots = [1, 3, 5].compactMap { idx in payload.slots.first(where: { $0.position.rawValue == idx }) }
        let bottomSlots = [2, 4, 6].compactMap { idx in payload.slots.first(where: { $0.position.rawValue == idx }) }

        return VStack(spacing: 8) {
            // Top bar
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(layerAccent(payload.layer))
                        .frame(width: 7, height: 7)
                    Text(payload.layerSourceLabel.map { "\($0) · \(payload.layer.badgeLabel)" } ?? payload.layer.badgeLabel)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(layerAccent(payload.layer))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(layerAccent(payload.layer).opacity(0.14)))

                Text(payload.headline)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let threadTitle = payload.threadTitle {
                    Text(threadTitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 170, alignment: .trailing)
                }
            }

            // H-Gate Top Row (1, 3, 5)
            HStack(spacing: 7) {
                ForEach(topSlots) { slot in
                    hudSlotCard(slot)
                }
                Spacer()
                    .frame(width: 96)
            }

            // Neutral center bar
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 1.5)
                Text(payload.kind == .decision ? "NEUTRAL" : payload.detail)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(payload.kind == .decision ? Color(hex: "#38BDF8") : Color.white.opacity(0.6))
                    .lineLimit(1)
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 1.5)
            }
            .padding(.horizontal, 6)

            // H-Gate Bottom Row (2, 4, 6, R)
            HStack(spacing: 7) {
                ForEach(bottomSlots) { slot in
                    hudSlotCard(slot)
                }
                reverseCard(label: payload.reverseLabel, isActive: payload.kind == .engaged(.reverse))
            }

            // Footer hints
            if payload.kind == .decision {
                HStack(spacing: 12) {
                    Text("⇧ Shift: Effort")
                    Text("⌥ Option: T3 Modes")
                    Text("(P): Park / Hold Fast")
                    Spacer()
                    Text(payload.detail)
                        .lineLimit(1)
                }
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.45))
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.055, green: 0.068, blue: 0.095).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.6), radius: 22, y: 10)
        )
    }

    private func hudSlotCard(_ slot: HUDGateSlot) -> some View {
        let accent = Color(hex: slot.accentHex)
        return HStack(spacing: 6) {
            Text(slot.position.label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(slot.isActive ? .black : accent)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(slot.isActive ? accent : accent.opacity(0.16))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(slot.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let sub = slot.subtitle {
                    Text(sub)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.52))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if slot.isCurrentThreadValue {
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(slot.isActive ? accent.opacity(0.24) : Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            slot.isActive ? accent : (slot.isCurrentThreadValue ? accent.opacity(0.45) : Color.white.opacity(0.08)),
                            lineWidth: slot.isActive ? 1.5 : 1
                        )
                )
        )
    }

    private func reverseCard(label: String, isActive: Bool) -> some View {
        let clean = label.replacingOccurrences(of: "R · ", with: "")
        return HStack(spacing: 5) {
            Text("R")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? .black : Color(hex: "#F59E0B"))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isActive ? Color(hex: "#F59E0B") : Color(hex: "#F59E0B").opacity(0.18))
                )
            Text(clean)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(width: 96)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive ? Color(hex: "#F59E0B").opacity(0.24) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(isActive ? Color(hex: "#F59E0B") : Color.white.opacity(0.09), lineWidth: 1)
                )
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
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color))
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
