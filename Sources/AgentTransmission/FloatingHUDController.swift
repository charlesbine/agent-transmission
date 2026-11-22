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

        let hosting = NSHostingView(rootView: FloatingShiftHUDView(
            state: state,
            parkHintProvider: { [weak model] in
                guard let b = model?.bindings else { return "(P) Park / Hold Fast" }
                return "(P) \(b.parkTapAction.shortLabel) · Hold \(b.parkHoldAction.shortLabel)"
            },
            onDismiss: { [weak self] in
                self?.model.disarmOneShotLayer()
                self?.dismiss()
            }
        ))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func present(_ payload: ShiftHUDPayload) {
        let panel = ensurePanel()
        hideWorkItem?.cancel()

        // Allow clicking the dismiss (×) button on the Decision HUD without stealing app focus;
        // brief engaged/action toasts stay click-through.
        panel.ignoresMouseEvents = payload.kind != .decision

        state.payload = payload
        let targetWidth: CGFloat
        let targetHeight: CGFloat
        if case .parkHolding = payload.kind {
            targetWidth = 520
            targetHeight = 148
        } else if payload.slots.isEmpty {
            targetWidth = 460
            targetHeight = 104
        } else {
            targetWidth = 696
            targetHeight = 314
        }

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

struct FloatingShiftHUDView: View {
    @ObservedObject var state: FloatingHUDState
    let parkHintProvider: () -> String
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if let payload = state.payload {
                if case let .parkHolding(startedAt, holdDuration, tapLabel, holdLabel, chordLabel) = payload.kind {
                    parkHoldGuide(
                        payload: payload,
                        startedAt: startedAt,
                        holdDuration: holdDuration,
                        tapLabel: tapLabel,
                        holdLabel: holdLabel,
                        chordLabel: chordLabel
                    )
                } else if payload.slots.isEmpty {
                    compactToast(payload)
                } else {
                    gateOverlay(payload)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
    }

    private func parkHoldGuide(
        payload: ShiftHUDPayload,
        startedAt: Date,
        holdDuration: TimeInterval,
        tapLabel: String,
        holdLabel: String,
        chordLabel: String?
    ) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            let progress = min(1.0, elapsed / max(holdDuration, 0.1))
            let remaining = max(0, holdDuration - elapsed)
            let amber = Color(hex: "#F59E0B")
            let cyan = Color(hex: "#38BDF8")

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text("P")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(amber))

                    Text("Holding (P) Switch")
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)

                    Spacer()

                    Text(remaining > 0.05 ? String(format: "%.1fs to hold action", remaining) : "TRIGGERING…")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(amber)
                }

                HStack(spacing: 10) {
                    // Release-now card
                    VStack(alignment: .leading, spacing: 3) {
                        Text("RELEASE NOW")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(cyan)
                        Text(tapLabel)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(cyan.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(cyan.opacity(0.45), lineWidth: 1)
                            )
                    )

                    // Keep-holding card with live progress fill
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("KEEP HOLDING")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(amber)
                            Spacer()
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(amber.opacity(0.85))
                        }
                        Text(holdLabel)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.10))
                                Capsule()
                                    .fill(amber)
                                    .frame(width: max(4, geo.size.width * progress))
                            }
                        }
                        .frame(height: 5)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(amber.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(amber.opacity(0.55), lineWidth: 1)
                            )
                    )
                }

                if let chordLabel {
                    HStack {
                        Text(chordLabel)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.48))
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.052, green: 0.064, blue: 0.092).opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(amber.opacity(0.4), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.65), radius: 24, y: 10)
            )
        }
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
                        .frame(maxWidth: 210, alignment: .trailing)
                }

                if payload.kind == .decision {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(Color.white.opacity(0.55))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.white.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss HUD")
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
                    HStack(spacing: 9) {
                        Text("⇧ Effort")
                        Text("·").foregroundColor(Color.white.opacity(0.25))
                        Text("⌥ Modes")
                        Text("·").foregroundColor(Color.white.opacity(0.25))
                        Text(parkHintProvider())
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

            // Smooth draining countdown bar when Decision/One-Shot HUD is timed
            if payload.kind == .decision, let delay = payload.autoHideDelay, delay > 0 {
                if payload.modifierActive {
                    Capsule()
                        .fill(accent.opacity(0.55))
                        .frame(height: 3)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let elapsed = max(0, context.date.timeIntervalSince(payload.emittedAt))
                        let remainingRatio = max(0, min(1, 1.0 - elapsed / delay))
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule()
                                    .fill(accent.opacity(0.75))
                                    .frame(width: geo.size.width * remainingRatio)
                            }
                        }
                        .frame(height: 3)
                    }
                }
            }
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
            case .parkHolding: return ("P", Color(hex: "#F59E0B"))
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
