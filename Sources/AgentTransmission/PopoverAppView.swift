import AppKit
import SwiftUI
import AgentTransmissionCore

enum PopoverTab: String, CaseIterable {
    case gearbox = "Gearbox"
    case controls = "Controls"
}

struct PopoverAppView: View {
    @ObservedObject var model: AppModel
    let launchAtLogin: LaunchAtLoginController
    let onQuit: () -> Void

    @State private var activeTab: PopoverTab = .gearbox
    @State private var selectedGear: GearPosition = .first
    @State private var providerFilter: String = "__favorites__"
    @State private var searchText: String = ""
    @State private var launchError: String?

    private var availableProviders: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in model.catalogModels {
            if seen.insert(entry.providerLabel).inserted {
                result.append(entry.providerLabel)
            }
        }
        return result
    }

    private var filteredCatalog: [CatalogModelSummary] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let favoritesExist = model.catalogModels.contains(where: \.isFavorite)

        let base: [CatalogModelSummary]
        if !q.isEmpty {
            base = model.catalogModels.filter {
                $0.displayName.lowercased().contains(q)
                    || $0.slug.lowercased().contains(q)
                    || $0.providerLabel.lowercased().contains(q)
            }
        } else if providerFilter == "__favorites__" {
            base = favoritesExist ? model.catalogModels.filter(\.isFavorite) : model.catalogModels
        } else if providerFilter == "__all__" {
            base = model.catalogModels
        } else {
            base = model.catalogModels.filter { $0.providerLabel == providerFilter }
        }

        // Always keep ★ Favorites pinned to the top within any view.
        return base.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            return false
        }
    }

    private var selectedPreset: ModelPreset {
        model.map.preset(for: selectedGear) ?? model.map.forward[0]
    }

    private var selectedModelSummary: CatalogModelSummary? {
        model.catalogModels.first(where: {
            $0.slug == selectedPreset.model && (selectedPreset.provider == nil || $0.providerInstanceID == selectedPreset.provider)
        }) ?? model.catalogModels.first(where: { $0.slug == selectedPreset.model })
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider().overlay(Color.white.opacity(0.08))
            tabAndQuickControlsBar
            Divider().overlay(Color.white.opacity(0.08))

            if activeTab == .gearbox {
                gearboxTab
            } else {
                controlsTab
            }

            Divider().overlay(Color.white.opacity(0.08))
            footerBar
        }
        .frame(width: 456, height: 760)
        .background(Color(red: 0.065, green: 0.078, blue: 0.102))
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.targetControlConnected ? Color(hex: "#10B981") : Color(hex: "#F59E0B"))
                    .frame(width: 8, height: 8)

                Text("Agent Transmission")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                if model.controlSurfaceConnected {
                    Text("HID")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "#38BDF8"))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(hex: "#38BDF8").opacity(0.15)))
                } else {
                    Text("No Shifter")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.45))
                }

                Spacer()

                if !model.availableTargetKinds.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(model.availableTargetKinds, id: \.rawValue) { kind in
                            let isSelected = model.selectedTargetKind == kind
                            Button(kind == .t3Code ? "T3 Code" : "Codex") {
                                model.selectAgentTarget(kind)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? .black : Color.white.opacity(0.7))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                Capsule().fill(isSelected ? Color(hex: "#38BDF8") : Color.clear)
                            )
                        }
                    }
                    .padding(2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }

            // Focused thread card
            HStack(spacing: 8) {
                Menu {
                    Button {
                        model.selectAutomaticTarget()
                    } label: {
                        Text(model.targetSelection == .automatic ? "✓ Auto · Focused \(model.agentTargetName) Thread" : "Auto · Focused \(model.agentTargetName) Thread")
                    }
                    Divider()
                    ForEach(model.tasks.prefix(15), id: \.id) { task in
                        Button {
                            model.pinTarget(task.id)
                        } label: {
                            let pinned = model.targetSelection == .pinned(task.id)
                            Text("\(pinned ? "✓ " : "")\(task.title) — \(task.workspace)")
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.targetSelection == .automatic ? "scope" : "pin.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#38BDF8"))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.targetTask?.title ?? "No active thread")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            if let live = model.currentThreadState {
                                Text("\(live.modelLabel)\(live.effort.map { " · \($0.shortLabel)" } ?? "") · \(live.interactionMode.displayLabel) · \(live.runtimeMode.shortLabel)")
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .foregroundColor(Color.white.opacity(0.55))
                                    .lineLimit(1)
                            } else {
                                Text(model.status)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundColor(Color.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(Color.white.opacity(0.4))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.055))
                    )
                }
                .menuStyle(.borderlessButton)

                if model.targetTask != nil {
                    Button {
                        model.openTarget()
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 13))
                            .foregroundColor(Color.white.opacity(0.75))
                            .frame(width: 30, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Open focused thread in \(model.agentTargetName)")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Tab & Quick Pill Bar

    private var tabAndQuickControlsBar: some View {
        HStack(spacing: 6) {
            ForEach(PopoverTab.allCases, id: \.self) { tab in
                let active = activeTab == tab
                Button(tab.rawValue) {
                    activeTab = tab
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                .foregroundColor(active ? .white : Color.white.opacity(0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Color.white.opacity(0.12) : Color.clear)
                )
            }

            Spacer()

            quickPill(
                label: model.parked ? "P · Parked" : "P",
                active: model.parked,
                tint: Color(hex: "#F59E0B")
            ) {
                model.toggleParkingBrake()
            }

            quickPill(
                label: "⚡ Fast",
                active: model.fastMode,
                tint: Color(hex: "#38BDF8")
            ) {
                model.toggleFastMode()
            }

            if model.supportsRichControlActions {
                let isPlan = model.currentThreadState?.interactionMode == .plan
                quickPill(
                    label: isPlan ? "Plan" : "Code",
                    active: isPlan,
                    tint: Color(hex: "#A78BFA")
                ) {
                    model.togglePlanMode()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func quickPill(label: String, active: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(active ? .black : Color.white.opacity(0.75))
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(
                    Capsule().fill(active ? tint : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Gearbox Tab

    private var gearboxTab: some View {
        VStack(spacing: 10) {
            // Mode + One-Click Preset Actions
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        ForEach(GearboxMode.allCases, id: \.self) { mode in
                            let selected = model.bindings.gearboxMode == mode
                            Button(mode.displayLabel) {
                                model.updateBindings { $0.gearboxMode = mode }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                            .foregroundColor(selected ? .white : Color.white.opacity(0.55))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? Color.white.opacity(0.14) : Color.clear)
                            )
                        }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))

                    Spacer()

                    Button {
                        model.syncFromFavorites()
                    } label: {
                        Label("Sync ★", systemImage: "star.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(hex: "#F59E0B"))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4.5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(hex: "#F59E0B").opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .help("Fill gears 1–6 from your T3 Code ★ Favorites")

                    Menu {
                        Button("1 → 6: Fast → Smart") { model.sortGears(fastToSmart: true) }
                        Button("1 → 6: Smart → Fast") { model.sortGears(fastToSmart: false) }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.arrow.down")
                            Text("Sort")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.8))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4.5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.08)))
                    }
                    .menuStyle(.borderlessButton)
                }

                HStack {
                    Text(model.bindings.gearboxMode.subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.48))
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            // Interactive Visual H-Gate
            interactiveHGate
                .padding(.horizontal, 14)

            Divider().overlay(Color.white.opacity(0.08))

            // Inline Gear Inspector (NEVER closes!)
            gearInspector
        }
    }

    private var interactiveHGate: some View {
        let activeLayer: GearLayer = model.bindings.gearboxMode == .effort
            ? .effort
            : (model.bindings.gearboxMode == .custom ? .custom : .models)
        let slots = model.hudSlots(for: activeLayer, highlighted: model.lastGear)
        let accent: Color = {
            switch activeLayer {
            case .models: Color(hex: "#38BDF8")
            case .effort: Color(hex: "#A78BFA")
            case .permissions: Color(hex: "#F59E0B")
            case .custom: Color(hex: "#10B981")
            }
        }()

        return HGateDiagramView(
            style: .popover,
            slots: slots,
            reverseTitle: model.bindings.reverseAction.shortLabel,
            reverseSubtitle: "Reverse",
            activeGear: model.lastGear,
            editingGear: selectedGear,
            isNeutral: model.inNeutral,
            layerAccent: accent,
            onSelectSlot: { pos in
                selectedGear = pos
            }
        )
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.32))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Inline Gear Inspector

    private var gearInspector: some View {
        VStack(spacing: 8) {
            if selectedGear == .reverse {
                HStack {
                    Text("Reverse (R) Action")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    uniformDropdown(
                        title: model.bindings.reverseAction.displayLabel,
                        options: ReverseGearAction.allCases,
                        selected: model.bindings.reverseAction,
                        label: \.displayLabel,
                        width: 224
                    ) { newVal in
                        model.updateBindings { $0.reverseAction = newVal }
                    }
                }
                .padding(.horizontal, 14)
            }

            let showModelPicker = selectedGear != .reverse
                || model.bindings.reverseAction == .reviewPreset
                || model.bindings.reverseAction == .seventhGear

            if showModelPicker {
                // Selected slot header + effort segmented bar
                HStack(spacing: 8) {
                    Text("Gear \(selectedGear.label)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "#38BDF8"))
                    Text(selectedPreset.displayLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 14)

                // Supported efforts bar for this model
                let efforts = selectedModelSummary?.supportedEfforts ?? ReasoningEffort.allCases
                HStack(spacing: 4) {
                    Text("Effort")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.5))
                    Spacer(minLength: 4)
                    ForEach(efforts, id: \.self) { effort in
                        let isChosen = selectedPreset.effort == effort
                        Button(effort.shortLabel) {
                            let updated = ModelPreset(
                                name: selectedPreset.name,
                                model: selectedPreset.model,
                                effort: effort,
                                provider: selectedPreset.provider
                            )
                            model.configure(selectedGear, preset: updated)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: isChosen ? .bold : .medium, design: .monospaced))
                        .foregroundColor(isChosen ? .black : Color.white.opacity(0.75))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isChosen ? Color(hex: "#38BDF8") : Color.white.opacity(0.07))
                        )
                    }
                }
                .padding(.horizontal, 14)

                // Provider filter pills + Search
                VStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            filterChip(id: "__favorites__", label: "★ Favorites")
                            filterChip(id: "__all__", label: "All (\(model.catalogModels.count))")
                            ForEach(availableProviders, id: \.self) { provider in
                                filterChip(id: provider, label: provider)
                            }
                        }
                        .padding(.horizontal, 14)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10.5))
                            .foregroundColor(Color.white.opacity(0.4))
                        TextField("Filter models…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
                    .padding(.horizontal, 14)
                }

                // Compact model list
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filteredCatalog) { entry in
                            let isAssigned = selectedPreset.model == entry.slug
                                && (selectedPreset.provider == nil || selectedPreset.provider == entry.providerInstanceID)
                            let cleanRowName: String = {
                                let suffix = " (\(entry.providerLabel))"
                                return entry.displayName.hasSuffix(suffix)
                                    ? String(entry.displayName.dropLast(suffix.count))
                                    : entry.displayName
                            }()
                            Button {
                                let chosenEffort = entry.supportedEfforts.contains(selectedPreset.effort)
                                    ? selectedPreset.effort
                                    : entry.defaultEffort
                                model.configure(selectedGear, preset: entry.preset(effort: chosenEffort))
                            } label: {
                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(Color(hex: entry.accentColorHex))
                                        .frame(width: 7, height: 7)
                                    if entry.isFavorite {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 8.5))
                                            .foregroundColor(Color(hex: "#F59E0B"))
                                    }
                                    Text(cleanRowName)
                                        .font(.system(size: 11.5, weight: isAssigned ? .semibold : .regular))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(entry.providerLabel)
                                        .font(.system(size: 9.5))
                                        .foregroundColor(Color.white.opacity(0.45))
                                    if isAssigned {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(Color(hex: "#38BDF8"))
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(isAssigned ? Color(hex: "#38BDF8").opacity(0.14) : Color.white.opacity(0.025))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer()
                Text("Reverse (R) is bound to \"\(model.bindings.reverseAction.displayLabel)\".\nSwitch to Review Preset or 7th Gear above to assign a model.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            }
        }
    }

    private func filterChip(id: String, label: String) -> some View {
        let active = providerFilter == id
        return Button(label) {
            providerFilter = id
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: active ? .semibold : .medium))
        .foregroundColor(active ? .black : Color.white.opacity(0.72))
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            Capsule().fill(active ? Color.white : Color.white.opacity(0.08))
        )
    }

    // MARK: - Controls Tab

    private var controlsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                sectionHeader("PHYSICAL SWITCHES")
                bindingRow("Reverse (R)") {
                    uniformDropdown(
                        title: model.bindings.reverseAction.displayLabel,
                        options: ReverseGearAction.allCases,
                        selected: model.bindings.reverseAction,
                        label: \.displayLabel
                    ) { v in model.updateBindings { $0.reverseAction = v } }
                }

                bindingRow("Tap (P) Switch") {
                    uniformDropdown(
                        title: model.bindings.parkTapAction.displayLabel,
                        options: ParkButtonAction.allCases,
                        selected: model.bindings.parkTapAction,
                        label: \.displayLabel
                    ) { v in model.updateBindings { $0.parkTapAction = v } }
                }

                bindingRow("Hold (P) 1.2s") {
                    uniformDropdown(
                        title: model.bindings.parkHoldAction.displayLabel,
                        options: ParkButtonAction.allCases,
                        selected: model.bindings.parkHoldAction,
                        label: \.displayLabel
                    ) { v in model.updateBindings { $0.parkHoldAction = v } }
                }

                bindingRow("Sequential (S+ / S−)") {
                    uniformDropdown(
                        title: model.bindings.sequentialAction.displayLabel,
                        options: SequentialPaddleAction.allCases,
                        selected: model.bindings.sequentialAction,
                        label: \.displayLabel
                    ) { v in model.updateBindings { $0.sequentialAction = v } }
                }

                Divider().overlay(Color.white.opacity(0.08))
                sectionHeader("MODIFIER LAYERS (HOLD + GEAR 1–6)")

                bindingRow("⇧ Shift + Gear") {
                    uniformDropdown(
                        title: model.bindings.shiftModifierLayer.displayLabel,
                        options: ModifierLayerAction.allCases,
                        selected: model.bindings.shiftModifierLayer,
                        label: \.displayLabel
                    ) { v in model.updateBindings { $0.shiftModifierLayer = v } }
                }

                bindingRow("⌥ Option + Gear") {
                    uniformDropdown(
                        title: model.bindings.optionModifierLayer.displayLabel,
                        options: ModifierLayerAction.allCases,
                        selected: model.bindings.optionModifierLayer,
                        label: \.displayLabel
                    ) { v in model.updateBindings { $0.optionModifierLayer = v } }
                }

                bindingRow("(P) Hold + Gear") {
                    uniformDropdown(
                        title: model.bindings.parkChordLayer.displayLabel,
                        options: ModifierLayerAction.allCases,
                        selected: model.bindings.parkChordLayer,
                        label: \.displayLabel
                    ) { v in model.updateBindings { $0.parkChordLayer = v } }
                }

                Divider().overlay(Color.white.opacity(0.08))
                sectionHeader("FLOATING SHIFT HUD & SYNC")

                Toggle("Show Floating Shift HUD", isOn: Binding(
                    get: { model.bindings.showFloatingHUD },
                    set: { v in model.updateBindings { $0.showFloatingHUD = v } }
                ))
                .font(.system(size: 11.5))

                Toggle("Pop Decision HUD on Gear → Neutral", isOn: Binding(
                    get: { model.bindings.showHUDOnNeutral },
                    set: { v in model.updateBindings { $0.showHUDOnNeutral = v } }
                ))
                .font(.system(size: 11.5))
                .disabled(!model.bindings.showFloatingHUD)

                bindingRow("Neutral HUD stays open") {
                    uniformDropdown(
                        title: model.bindings.neutralHUDTimeout.displayLabel,
                        options: NeutralHUDTimeout.allCases,
                        selected: model.bindings.neutralHUDTimeout,
                        label: \.displayLabel
                    ) { v in model.updateBindings { $0.neutralHUDTimeout = v } }
                }
                .disabled(!model.bindings.showFloatingHUD || !model.bindings.showHUDOnNeutral)

                bindingRow("Shift toast duration") {
                    uniformDropdown(
                        title: model.bindings.engagedHUDTimeout.displayLabel,
                        options: EngagedHUDTimeout.allCases,
                        selected: model.bindings.engagedHUDTimeout,
                        label: \.displayLabel
                    ) { v in model.updateBindings { $0.engagedHUDTimeout = v } }
                }
                .disabled(!model.bindings.showFloatingHUD)

                Toggle("Auto-sync 1–6 with T3 ★ Favorites", isOn: Binding(
                    get: { model.bindings.autoSyncFavorites },
                    set: { v in model.updateBindings { $0.autoSyncFavorites = v } }
                ))
                .font(.system(size: 11.5))

                HStack(spacing: 8) {
                    Button("Preview Decision HUD") {
                        model.previewDecisionHUD()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(launchAtLogin.state == .enabled ? "Launch at Login: On" : "Launch at Login: Off") {
                        do {
                            try launchAtLogin.toggle()
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let launchError {
                    Text(launchError)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }
            .padding(14)
        }
    }

    private func uniformDropdown<T: Hashable>(
        title: String,
        options: [T],
        selected: T,
        label: KeyPath<T, String>,
        width: CGFloat = 224,
        onSelect: @escaping (T) -> Void
    ) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    Text(option == selected ? "✓ \(option[keyPath: label])" : option[keyPath: label])
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.075))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.white.opacity(0.11), lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .frame(width: width)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundColor(Color.white.opacity(0.45))
    }

    private func bindingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundColor(Color.white.opacity(0.88))
            Spacer()
            content()
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button("Reconnect") {
                model.reconnect()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(Color.white.opacity(0.65))

            Button("Restore Defaults") {
                model.restoreDefaultMap()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(Color.white.opacity(0.65))

            Spacer()

            Button("Quit") {
                onQuit()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(Color(hex: "#F87171"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
