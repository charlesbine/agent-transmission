import XCTest
@testable import AgentTransmission
@testable import AgentTransmissionCore

final class TransmissionV2Tests: XCTestCase {
    func testGearToNeutralEmitsEnteredNeutralAfterSettleAndAllowsReengage() {
        var sm = ShifterStateMachine(settleInterval: 0.025, neutralSettleInterval: 0.100)

        XCTAssertEqual(sm.sample(buttons: [4], at: 0.000), [])
        XCTAssertEqual(sm.sample(buttons: [4], at: 0.030), [.engaged(.fourth)])
        // Pull to neutral
        XCTAssertEqual(sm.sample(buttons: [], at: 0.050), [])
        // Short 40ms bounce: NOT settled into neutral yet
        XCTAssertEqual(sm.sample(buttons: [], at: 0.090), [])
        // Past 100ms in neutral: emits enteredNeutral
        XCTAssertEqual(sm.sample(buttons: [], at: 0.160), [.enteredNeutral])
        // Re-engaging 4th gear after genuine neutral now registers cleanly
        XCTAssertEqual(sm.sample(buttons: [4], at: 0.200), [])
        XCTAssertEqual(sm.sample(buttons: [4], at: 0.230), [.engaged(.fourth)])
    }

    func testNeutralTriggersDecisionHUDWithoutApplyingSettings() {
        let suite = "TransmissionV2Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let surface = V2FakeSurface()
        let target = V2FakeRichTarget()
        let model = AppModel(
            controlSurface: surface,
            initialTargetKind: .t3Code,
            targetFactory: { _ in target },
            defaults: defaults,
            modifierProvider: { ActiveKeyboardModifiers() }
        )

        var hudEvents: [ShiftHUDPayload] = []
        model.onHUDUpdate = { hudEvents.append($0) }

        model.start()
        surface.emit([.enteredNeutral])

        XCTAssertTrue(model.inNeutral)
        XCTAssertNil(target.lastAppliedUpdate, "Neutral must never apply model settings")
        XCTAssertEqual(hudEvents.last?.kind, .decision)
        XCTAssertEqual(hudEvents.last?.layer, .models)
        XCTAssertEqual(hudEvents.last?.slots.count, 6)
    }

    func testShiftAndOptionModifiersAndReversePlanToggle() {
        let suite = "TransmissionV2Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let surface = V2FakeSurface()
        let target = V2FakeRichTarget()
        var currentMods = ActiveKeyboardModifiers()
        let model = AppModel(
            controlSurface: surface,
            initialTargetKind: .t3Code,
            targetFactory: { _ in target },
            defaults: defaults,
            modifierProvider: { currentMods }
        )

        model.start()

        // 1. Shift + Gear 5 -> Effort Max on active thread's model
        currentMods = ActiveKeyboardModifiers(shift: true, option: false)
        surface.emit([.selectPosition(.fifth)])
        XCTAssertEqual(target.lastAppliedUpdate?.preset?.model, "claude-opus-5-5")
        XCTAssertEqual(target.lastAppliedUpdate?.preset?.effort, .max)

        // 2. Option + Gear 4 -> RuntimeMode full-access
        currentMods = ActiveKeyboardModifiers(shift: false, option: true)
        surface.emit([.selectPosition(.fourth)])
        XCTAssertEqual(target.lastRuntimeMode, .fullAccess)

        // 3. Option + Gear 5 -> Plan mode
        surface.emit([.selectPosition(.fifth)])
        XCTAssertEqual(target.lastInteractionMode, .plan)

        // 4. Reverse (default on T3: toggle Plan <-> Code) highlights Reverse on the HUD
        var hudEvents: [ShiftHUDPayload] = []
        model.onHUDUpdate = { hudEvents.append($0) }
        currentMods = ActiveKeyboardModifiers()
        target.liveInteractionMode = .plan
        surface.emit([.selectPosition(.reverse)])
        XCTAssertEqual(target.lastInteractionMode, .defaultMode)
        XCTAssertEqual(hudEvents.last?.kind, .engaged(.reverse))
    }

    func testSyncFromFavoritesAndSortFastToSmart() {
        let suite = "TransmissionV2Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let surface = V2FakeSurface()
        let target = V2FakeRichTarget()
        let model = AppModel(
            controlSurface: surface,
            initialTargetKind: .t3Code,
            targetFactory: { _ in target },
            defaults: defaults
        )

        model.syncFromFavorites()
        XCTAssertEqual(model.map.forward.count, 6)
        XCTAssertEqual(model.map.forward[0].model, "claude-opus-5-5")

        model.sortGears(fastToSmart: true)
        XCTAssertEqual(model.map.forward.first?.model, "claude-haiku-5-5")
        XCTAssertEqual(model.map.forward.last?.model, "claude-opus-5-5")
    }

    func testModelTierRankOrdersLargerSmarterModelsHigher() {
        let haiku = T3CodeAgentTarget.modelTierRank(slug: "claude-haiku-5-5", displayName: "Claude Haiku 5.5")
        let hydrogen = T3CodeAgentTarget.modelTierRank(slug: "gemini-4-hydrogen", displayName: "Gemini 4 Hydrogen")
        let sol = T3CodeAgentTarget.modelTierRank(slug: "gpt-6.2-sol", displayName: "GPT-6.2 Sol")
        let neon = T3CodeAgentTarget.modelTierRank(slug: "gemini-4-neon", displayName: "Gemini 4 Neon")
        let opus = T3CodeAgentTarget.modelTierRank(slug: "claude-opus-5-5", displayName: "Claude Opus 5.5")
        let fable = T3CodeAgentTarget.modelTierRank(slug: "claude-fable-5-2", displayName: "Claude Fable 5.2")
        let astra = T3CodeAgentTarget.modelTierRank(slug: "gpt-6.2-astra", displayName: "GPT-6.2 Astra")
        let carbon = T3CodeAgentTarget.modelTierRank(slug: "gemini-4-carbon", displayName: "Gemini 4 Carbon")

        XCTAssertLessThan(haiku, hydrogen)
        XCTAssertLessThan(hydrogen, sol)
        XCTAssertLessThan(sol, neon)
        XCTAssertLessThan(neon, opus)
        XCTAssertLessThan(opus, fable)
        XCTAssertLessThan(sol, astra)
        XCTAssertLessThan(neon, carbon)
    }

    func testOneShotTapParkArmsEffortForSingleShiftAndShowsHoldHUD() {
        let suite = "TransmissionV2Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let surface = V2FakeSurface()
        let target = V2FakeRichTarget()
        let model = AppModel(
            controlSurface: surface,
            initialTargetKind: .t3Code,
            targetFactory: { _ in target },
            defaults: defaults,
            modifierProvider: { ActiveKeyboardModifiers() }
        )

        var hudEvents: [ShiftHUDPayload] = []
        model.onHUDUpdate = { hudEvents.append($0) }
        model.start()

        // Press (P) -> immediately pops Hold Guide HUD with progress info
        surface.emit([.modifierChanged(true)])
        if case .parkHolding = hudEvents.last?.kind {
            // expected
        } else {
            XCTFail("Expected .parkHolding HUD when (P) is pressed down")
        }

        // Release (P) quickly -> arms One-Shot Effort layer (t3Default tap action)
        surface.emit([.modifierChanged(false)])
        XCTAssertEqual(model.armedOneShotLayer, .effort)
        XCTAssertEqual(hudEvents.last?.kind, .decision)
        XCTAssertEqual(hudEvents.last?.layer, .effort)
        XCTAssertEqual(hudEvents.last?.layerSourceLabel, "ONE-SHOT")

        // Next gear shift applies Effort (5 -> Max) and automatically disarms back to Models
        surface.emit([.selectPosition(.fifth)])
        XCTAssertNil(model.armedOneShotLayer)
        XCTAssertEqual(target.lastAppliedUpdate?.preset?.model, "claude-opus-5-5")
        XCTAssertEqual(target.lastAppliedUpdate?.preset?.effort, .max)

        // Following gear shift returns to normal Models mode (gear 2 -> Haiku)
        surface.emit([.selectPosition(.second)])
        XCTAssertEqual(target.lastAppliedUpdate?.preset?.model, "claude-haiku-5-5")
    }
}

private final class V2FakeSurface: ControlSurface {
    let name = "Fake Shifter"
    var onEvents: (([ControlSurfaceEvent]) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?

    func start() { onConnectionChanged?(true) }
    func stop() {}
    func emit(_ events: [ControlSurfaceEvent]) { onEvents?(events) }
}

private final class V2FakeRichTarget: AgentTarget {
    let name = "T3 Code"
    let controlIsExperimental = false
    let supportsRichControlActions = true

    let catalogModels: [CatalogModelSummary] = [
        CatalogModelSummary(providerInstanceID: "claudeAgent", providerLabel: "Claude", accentColorHex: "#E07A5F", slug: "claude-opus-5-5", displayName: "Opus 5.5", isFavorite: true, supportedEfforts: [.low, .medium, .high, .xhigh, .max, .ultra], defaultEffort: .high, supportsFastMode: true, tierRank: 95),
        CatalogModelSummary(providerInstanceID: "claudeAgent", providerLabel: "Claude", accentColorHex: "#E07A5F", slug: "claude-haiku-5-5", displayName: "Haiku 5.5", isFavorite: true, supportedEfforts: [.low, .medium, .high], defaultEffort: .medium, supportsFastMode: false, tierRank: 10),
        CatalogModelSummary(providerInstanceID: "claudeAgent", providerLabel: "Claude", accentColorHex: "#E07A5F", slug: "claude-sonnet-5-5", displayName: "Sonnet 5.5", isFavorite: true, supportedEfforts: [.low, .medium, .high, .max], defaultEffort: .high, supportsFastMode: false, tierRank: 55),
        CatalogModelSummary(providerInstanceID: "codex", providerLabel: "Codex", accentColorHex: "#10B981", slug: "gpt-6-luna", displayName: "Luna", isFavorite: true, supportedEfforts: [.low, .medium, .high], defaultEffort: .medium, supportsFastMode: true, tierRank: 20),
        CatalogModelSummary(providerInstanceID: "codex", providerLabel: "Codex", accentColorHex: "#10B981", slug: "gpt-6.2-astra", displayName: "Astra", isFavorite: true, supportedEfforts: [.low, .medium, .high, .xhigh, .max], defaultEffort: .high, supportsFastMode: true, tierRank: 75),
        CatalogModelSummary(providerInstanceID: "antigravity", providerLabel: "Antigravity", accentColorHex: "#38BDF8", slug: "gemini-4-carbon", displayName: "Carbon", isFavorite: true, supportedEfforts: [.low, .medium, .high], defaultEffort: .high, supportsFastMode: false, tierRank: 40),
    ]

    var supportedPresets: [ModelPreset] {
        catalogModels.flatMap { m in m.supportedEfforts.map { m.preset(effort: $0) } }
    }

    var defaultTransmissionMap: TransmissionMap {
        TransmissionMap(
            forward: catalogModels.prefix(6).map { $0.preset() },
            reverse: catalogModels[0].preset(effort: .max)
        )
    }

    var onStateChanged: ((AgentTargetState) -> Void)?
    var onTasksChanged: (([AgentTask]) -> Void)?
    var onFocusedTaskChanged: ((String?) -> Void)?

    var liveInteractionMode: AgentInteractionMode = .defaultMode
    var liveRuntimeMode: AgentRuntimeMode = .auto
    var lastAppliedUpdate: AgentSettingsUpdate?
    var lastInteractionMode: AgentInteractionMode?
    var lastRuntimeMode: AgentRuntimeMode?

    func start() {
        onStateChanged?(.init(discoveryConnected: true, controlConnected: true))
        onTasksChanged?([.init(id: "th-1", title: "Active Thread", workspace: "lab", updatedAt: 100)])
        onFocusedTaskChanged?("th-1")
    }

    func stop() {}
    func reconnect() {}
    func refreshTasks() {}
    func stepEffort(from preset: ModelPreset, direction: Int) -> ModelPreset { preset }
    func stepModelFamily(from preset: ModelPreset, direction: Int) -> ModelPreset { preset }
    func taskURL(for taskID: String) -> URL? { URL(string: "t3code://threads/env/\(taskID)") }

    func currentThreadState(for taskID: String) -> AgentThreadLiveState? {
        AgentThreadLiveState(
            threadID: taskID,
            modelSlug: "claude-opus-5-5",
            providerInstanceID: "claudeAgent",
            modelLabel: "Opus 5.5",
            effort: .high,
            fastMode: false,
            interactionMode: liveInteractionMode,
            runtimeMode: liveRuntimeMode,
            isRunning: true
        )
    }

    func presetForEffortSlot(_ gearIndex: Int, on taskID: String, fallback: ModelPreset?) -> ModelPreset? {
        guard (1...6).contains(gearIndex) else { return nil }
        return catalogModels[0].preset(effort: ReasoningEffort.allCases[gearIndex - 1])
    }

    func apply(_ update: AgentSettingsUpdate, to taskID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        lastAppliedUpdate = update
        completion(.success(()))
    }

    func setInteractionMode(_ mode: AgentInteractionMode, for taskID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        lastInteractionMode = mode
        liveInteractionMode = mode
        completion(.success(()))
    }

    func setRuntimeMode(_ mode: AgentRuntimeMode, for taskID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        lastRuntimeMode = mode
        liveRuntimeMode = mode
        completion(.success(()))
    }
}
