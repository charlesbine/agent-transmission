import AppKit
import SwiftUI
import AgentTransmissionCore

// MARK: - Menu Bar Fixed-Width H-Gate Template Icon

enum HGateStatusBarIcon {
    /// Renders a razor-sharp macOS template icon (22x16 pt) depicting the 6+R H-pattern gate
    /// with a solid indicator dot at the active gear position (or center N / P badge).
    static func render(
        gear: GearPosition?,
        parked: Bool,
        inNeutral: Bool,
        connected: Bool
    ) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: true) { rect in
            let strokeColor = NSColor.labelColor.withAlphaComponent(connected ? 0.92 : 0.45)
            strokeColor.setStroke()
            strokeColor.setFill()

            // 4 column X centers for 1/2, 3/4, 5/6, and R
            let cols: [CGFloat] = [3.5, 8.5, 13.5, 18.5]
            let topY: CGFloat = 3.0
            let midY: CGFloat = 8.0
            let botY: CGFloat = 13.0

            let tracks = NSBezierPath()
            tracks.lineWidth = 1.35
            tracks.lineCapStyle = .round
            tracks.lineJoinStyle = .round

            // Horizontal neutral crossbar across all 4 columns
            tracks.move(to: NSPoint(x: cols[0], y: midY))
            tracks.line(to: NSPoint(x: cols[3], y: midY))

            // Vertical legs for 1-2, 3-4, 5-6
            for i in 0..<3 {
                tracks.move(to: NSPoint(x: cols[i], y: topY))
                tracks.line(to: NSPoint(x: cols[i], y: botY))
            }
            // Reverse drop-leg (only bottom right)
            tracks.move(to: NSPoint(x: cols[3], y: midY))
            tracks.line(to: NSPoint(x: cols[3], y: botY))
            tracks.stroke()

            // Indicator puck at active gear position
            let dotPoint: NSPoint?
            if parked {
                dotPoint = NSPoint(x: (cols[1] + cols[2]) / 2, y: midY)
            } else if inNeutral || gear == nil {
                dotPoint = NSPoint(x: (cols[1] + cols[2]) / 2, y: midY)
            } else {
                switch gear! {
                case .first: dotPoint = NSPoint(x: cols[0], y: topY)
                case .second: dotPoint = NSPoint(x: cols[0], y: botY)
                case .third: dotPoint = NSPoint(x: cols[1], y: topY)
                case .fourth: dotPoint = NSPoint(x: cols[1], y: botY)
                case .fifth: dotPoint = NSPoint(x: cols[2], y: topY)
                case .sixth: dotPoint = NSPoint(x: cols[2], y: botY)
                case .reverse: dotPoint = NSPoint(x: cols[3], y: botY)
                case .sequentialUp: dotPoint = NSPoint(x: cols[1], y: topY)
                case .sequentialDown: dotPoint = NSPoint(x: cols[1], y: botY)
                }
            }

            if let pt = dotPoint {
                let r: CGFloat = parked ? 2.6 : 2.35
                let dotRect = NSRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                if inNeutral && !parked {
                    // Hollow ring in neutral
                    NSColor.clear.setFill()
                    let ring = NSBezierPath(ovalIn: dotRect)
                    ring.lineWidth = 1.5
                    ring.stroke()
                } else {
                    NSBezierPath(ovalIn: dotRect).fill()
                }
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Shared Real H-Gate Visual Component (HUD + Popover)

enum HGateDisplayStyle {
    case hud
    case popover
}

struct HGateDiagramView: View {
    let style: HGateDisplayStyle
    let slots: [HUDGateSlot]
    let reverseTitle: String
    let reverseSubtitle: String
    let activeGear: GearPosition?
    let editingGear: GearPosition?
    let isNeutral: Bool
    let layerAccent: Color
    let onSelectSlot: ((GearPosition) -> Void)?

    private var isHUD: Bool { style == .hud }

    private static let cardBase = Color(red: 0.095, green: 0.112, blue: 0.148)

    private var columnSpacing: CGFloat { isHUD ? 12 : 7 }
    private var cardHeight: CGFloat { isHUD ? 72 : 52 }
    private var channelHeight: CGFloat { isHUD ? 44 : 34 }

    private func slot(at index: Int) -> HUDGateSlot? {
        slots.first(where: { $0.position.rawValue == index })
    }

    var body: some View {
        // 4-column physical H-gate card layout:
        // Top row:    [ 1 ]   [ 3 ]   [ 5 ]   (empty)
        // Center:     ======= Neutral Spine =======
        // Bottom row: [ 2 ]   [ 4 ]   [ 6 ]   [ R ]
        VStack(spacing: channelHeight) {
            HStack(spacing: columnSpacing) {
                slotView(for: 1)
                slotView(for: 3)
                slotView(for: 5)
                // 4th column top is empty on a 6+R shifter — show compact legend/badge
                fourthColumnTopHeader
            }

            HStack(spacing: columnSpacing) {
                slotView(for: 2)
                slotView(for: 4)
                slotView(for: 6)
                reverseCardView
            }
        }
        // Background GeometryReader inherits the exact tight VStack height —
        // zero wasted vertical space and rails stop flush between the two rows.
        .background(hPatternTracksOverlay)
    }

    private var hPatternTracksOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let colW = (w - columnSpacing * 3) / 4
            let colX: [CGFloat] = (0..<4).map { idx in
                CGFloat(idx) * (colW + columnSpacing) + colW / 2
            }

            let topEdgeY = cardHeight
            let botEdgeY = h - cardHeight
            let midY = h / 2
            let trackWidth: CGFloat = isHUD ? 7 : 5
            let innerWidth: CGFloat = isHUD ? 3 : 2

            ZStack {
                // Outer machined groove shadow
                Path { p in
                    // Horizontal neutral spine across all 4 columns
                    p.move(to: CGPoint(x: colX[0], y: midY))
                    p.addLine(to: CGPoint(x: colX[3], y: midY))
                    // Vertical legs 1-2, 3-4, 5-6
                    for i in 0..<3 {
                        p.move(to: CGPoint(x: colX[i], y: topEdgeY))
                        p.addLine(to: CGPoint(x: colX[i], y: botEdgeY))
                    }
                    // Right-hand drop leg into Reverse (R)
                    p.move(to: CGPoint(x: colX[3], y: midY))
                    p.addLine(to: CGPoint(x: colX[3], y: botEdgeY))
                }
                .stroke(
                    Color.black.opacity(0.65),
                    style: StrokeStyle(lineWidth: trackWidth + 3, lineCap: .round, lineJoin: .round)
                )

                // Recessed H-channel rail
                Path { p in
                    p.move(to: CGPoint(x: colX[0], y: midY))
                    p.addLine(to: CGPoint(x: colX[3], y: midY))
                    for i in 0..<3 {
                        p.move(to: CGPoint(x: colX[i], y: topEdgeY))
                        p.addLine(to: CGPoint(x: colX[i], y: botEdgeY))
                    }
                    p.move(to: CGPoint(x: colX[3], y: midY))
                    p.addLine(to: CGPoint(x: colX[3], y: botEdgeY))
                }
                .stroke(
                    Color.white.opacity(0.16),
                    style: StrokeStyle(lineWidth: trackWidth, lineCap: .round, lineJoin: .round)
                )

                // Illuminated active path (neutral spine glow or route to active gear)
                activePath(colX: colX, topEdgeY: topEdgeY, midY: midY, botEdgeY: botEdgeY)
                    .stroke(
                        isNeutral ? layerAccent.opacity(0.85) : activePathColor.opacity(0.9),
                        style: StrokeStyle(lineWidth: innerWidth, lineCap: .round, lineJoin: .round)
                    )

                // Center Neutral gate node / shift-puck
                let centerX = (colX[1] + colX[2]) / 2
                HStack(spacing: 4) {
                    Circle()
                        .fill(isNeutral ? layerAccent : Color.white.opacity(0.32))
                        .frame(width: isHUD ? 7 : 5, height: isHUD ? 7 : 5)
                    Text("N")
                        .font(.system(size: isHUD ? 10 : 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(isNeutral ? layerAccent : Color.white.opacity(0.48))
                }
                .padding(.horizontal, isHUD ? 9 : 6)
                .padding(.vertical, isHUD ? 3 : 2)
                .background(
                    Capsule()
                        .fill(Color(red: 0.06, green: 0.075, blue: 0.105))
                        .overlay(
                            Capsule()
                                .stroke(isNeutral ? layerAccent.opacity(0.85) : Color.white.opacity(0.18), lineWidth: 1)
                        )
                )
                .position(x: centerX, y: midY)

                // Junction dots where each vertical leg meets the neutral bar
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.28))
                        .frame(width: isHUD ? 5 : 4, height: isHUD ? 5 : 4)
                        .position(x: colX[i], y: midY)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var activePathColor: Color {
        if activeGear == .reverse { return Color(hex: "#F59E0B") }
        if let activeGear, let matched = slot(at: activeGear.rawValue) {
            return Color(hex: matched.accentHex)
        }
        return layerAccent
    }

    private func activePath(colX: [CGFloat], topEdgeY: CGFloat, midY: CGFloat, botEdgeY: CGFloat) -> Path {
        Path { p in
            let centerX = (colX[1] + colX[2]) / 2
            if isNeutral {
                p.move(to: CGPoint(x: colX[0], y: midY))
                p.addLine(to: CGPoint(x: colX[3], y: midY))
                return
            }
            guard let gear = activeGear else { return }
            switch gear {
            case .first:
                p.move(to: CGPoint(x: centerX, y: midY))
                p.addLine(to: CGPoint(x: colX[0], y: midY))
                p.addLine(to: CGPoint(x: colX[0], y: topEdgeY))
            case .second:
                p.move(to: CGPoint(x: centerX, y: midY))
                p.addLine(to: CGPoint(x: colX[0], y: midY))
                p.addLine(to: CGPoint(x: colX[0], y: botEdgeY))
            case .third:
                p.move(to: CGPoint(x: centerX, y: midY))
                p.addLine(to: CGPoint(x: colX[1], y: midY))
                p.addLine(to: CGPoint(x: colX[1], y: topEdgeY))
            case .fourth:
                p.move(to: CGPoint(x: centerX, y: midY))
                p.addLine(to: CGPoint(x: colX[1], y: midY))
                p.addLine(to: CGPoint(x: colX[1], y: botEdgeY))
            case .fifth:
                p.move(to: CGPoint(x: centerX, y: midY))
                p.addLine(to: CGPoint(x: colX[2], y: midY))
                p.addLine(to: CGPoint(x: colX[2], y: topEdgeY))
            case .sixth:
                p.move(to: CGPoint(x: centerX, y: midY))
                p.addLine(to: CGPoint(x: colX[2], y: midY))
                p.addLine(to: CGPoint(x: colX[2], y: botEdgeY))
            case .reverse:
                p.move(to: CGPoint(x: centerX, y: midY))
                p.addLine(to: CGPoint(x: colX[3], y: midY))
                p.addLine(to: CGPoint(x: colX[3], y: botEdgeY))
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var fourthColumnTopHeader: some View {
        VStack(alignment: .center, spacing: 2) {
            Text("6 + R")
                .font(.system(size: isHUD ? 11 : 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.28))
            Text(isHUD ? "H-GATE" : "CLICK SLOT")
                .font(.system(size: isHUD ? 9 : 8, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
    }

    @ViewBuilder
    private func slotView(for index: Int) -> some View {
        if let slot = slot(at: index) {
            let isEditing = editingGear == slot.position
            let isEngaged = activeGear == slot.position && !isNeutral
            let accent = Color(hex: slot.accentHex)

            let card = VStack(alignment: .leading, spacing: isHUD ? 5 : 3) {
                HStack(spacing: 5) {
                    Text(slot.position.label)
                        .font(.system(size: isHUD ? 11.5 : 10, weight: .bold, design: .monospaced))
                        .foregroundColor((isEngaged || isEditing) ? .black : accent)
                        .frame(width: isHUD ? 22 : 17, height: isHUD ? 22 : 17)
                        .background(
                            RoundedRectangle(cornerRadius: isHUD ? 6 : 4, style: .continuous)
                                .fill((isEngaged || isEditing) ? accent : accent.opacity(0.18))
                        )

                    Spacer(minLength: 0)

                    if isEngaged {
                        Text("LIVE")
                            .font(.system(size: isHUD ? 8.5 : 7.5, weight: .bold, design: .monospaced))
                            .foregroundColor(accent)
                    } else if slot.isCurrentThreadValue {
                        Circle()
                            .fill(accent)
                            .frame(width: isHUD ? 7 : 5.5, height: isHUD ? 7 : 5.5)
                    }
                }

                Text(slot.title)
                    .font(.system(size: isHUD ? 12.5 : 10.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let sub = slot.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: isHUD ? 10 : 8.5, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, isHUD ? 12 : 9)
            .padding(.vertical, isHUD ? 10 : 7)
            .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: isHUD ? 11 : 8, style: .continuous)
                    // Opaque base so the H-rail drawn behind never bleeds through the tint
                    .fill(Self.cardBase)
                    .overlay(
                        RoundedRectangle(cornerRadius: isHUD ? 11 : 8, style: .continuous)
                            .fill(isEngaged ? accent.opacity(0.24) : (isEditing ? accent.opacity(0.16) : Color.clear))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: isHUD ? 11 : 8, style: .continuous)
                            .stroke(
                                (isEngaged || isEditing)
                                    ? accent
                                    : (slot.isCurrentThreadValue ? accent.opacity(0.5) : Color.white.opacity(0.10)),
                                lineWidth: (isEngaged || isEditing) ? 1.75 : 1
                            )
                    )
            )

            if let onSelectSlot {
                Button {
                    onSelectSlot(slot.position)
                } label: {
                    card
                }
                .buttonStyle(.plain)
            } else {
                card
            }
        }
    }

    @ViewBuilder
    private var reverseCardView: some View {
        let isEditing = editingGear == .reverse
        let isEngaged = activeGear == .reverse && !isNeutral
        let tint = Color(hex: "#F59E0B")

        let card = VStack(alignment: .leading, spacing: isHUD ? 5 : 3) {
            HStack(spacing: 5) {
                Text("R")
                    .font(.system(size: isHUD ? 11.5 : 10, weight: .bold, design: .monospaced))
                    .foregroundColor((isEngaged || isEditing) ? .black : tint)
                    .frame(width: isHUD ? 22 : 17, height: isHUD ? 22 : 17)
                    .background(
                        RoundedRectangle(cornerRadius: isHUD ? 6 : 4, style: .continuous)
                            .fill((isEngaged || isEditing) ? tint : tint.opacity(0.2))
                    )
                Spacer(minLength: 0)
                if isEngaged {
                    Text("LIVE")
                        .font(.system(size: isHUD ? 8.5 : 7.5, weight: .bold, design: .monospaced))
                        .foregroundColor(tint)
                }
            }

            Text(reverseTitle)
                .font(.system(size: isHUD ? 12.5 : 10.5, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(reverseSubtitle)
                .font(.system(size: isHUD ? 10 : 8.5, weight: .medium))
                .foregroundColor(Color.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(.horizontal, isHUD ? 12 : 9)
        .padding(.vertical, isHUD ? 10 : 7)
        .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: isHUD ? 11 : 8, style: .continuous)
                .fill(Self.cardBase)
                .overlay(
                    RoundedRectangle(cornerRadius: isHUD ? 11 : 8, style: .continuous)
                        .fill(isEngaged ? tint.opacity(0.24) : (isEditing ? tint.opacity(0.16) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: isHUD ? 11 : 8, style: .continuous)
                        .stroke((isEngaged || isEditing) ? tint : Color.white.opacity(0.10), lineWidth: (isEngaged || isEditing) ? 1.75 : 1)
                )
        )

        if let onSelectSlot {
            Button {
                onSelectSlot(.reverse)
            } label: {
                card
            }
            .buttonStyle(.plain)
        } else {
            card
        }
    }
}
