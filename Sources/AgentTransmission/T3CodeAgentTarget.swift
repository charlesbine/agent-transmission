import Foundation
import AgentTransmissionCore

struct T3EffortOption: Equatable, Sendable {
    let effort: ReasoningEffort
    let rawOptionID: String?
    let isDefault: Bool
}

enum T3FastModeMapping: Equatable, Sendable {
    case boolean(optionID: String)
    case select(optionID: String, fastValue: String, standardValue: String)

    var optionID: String {
        switch self {
        case let .boolean(optionID): optionID
        case let .select(optionID, _, _): optionID
        }
    }

    func optionSelection(fastMode: Bool) -> T3ProviderOptionSelection {
        switch self {
        case let .boolean(optionID):
            T3ProviderOptionSelection(id: optionID, value: .bool(fastMode))
        case let .select(optionID, fastValue, standardValue):
            T3ProviderOptionSelection(id: optionID, value: .string(fastMode ? fastValue : standardValue))
        }
    }
}

struct T3CatalogModel: Equatable, Sendable {
    let instanceId: String
    let driver: String
    let providerLabel: String
    let slug: String
    let shortName: String
    let displayName: String
    let isDefault: Bool
    let isFavorite: Bool
    let reasoningOptionID: String?
    let efforts: [T3EffortOption]
    let fastModeMapping: T3FastModeMapping?

    func rawEffortOptionID(for effort: ReasoningEffort) -> String? {
        efforts.first(where: { $0.effort == effort })?.rawOptionID
    }
}

final class T3CodeAgentTarget: AgentTarget {
    let name = "T3 Code"
    let controlIsExperimental = false

    private(set) var supportedPresets: [ModelPreset]
    private(set) var defaultTransmissionMap: TransmissionMap

    var onStateChanged: ((AgentTargetState) -> Void)?
    var onTasksChanged: (([AgentTask]) -> Void)?
    var onFocusedTaskChanged: ((String?) -> Void)?

    private(set) var environmentID: String?
    private(set) var focusedThreadID: String?
    private(set) var orderedModels: [T3CatalogModel] = []

    private let client: any T3CodeClientProtocol
    private var connected = false
    private var lastConnectionMessage: String?

    private var projectsByID: [String: T3ProjectShell] = [:]
    private var threadsByID: [String: T3ThreadShell] = [:]
    private var lastAppOpenedThreadID: String?
    private var lastEmittedTasks: [AgentTask] = []

    private var providers: [T3ServerProvider] = []
    private var favorites: [T3ModelFavorite] = []
    private var providerModelPreferences: [String: T3ProviderModelPreference] = [:]

    private static let fallbackModels: [T3CatalogModel] = [
        T3CatalogModel(
            instanceId: "claudeAgent",
            driver: "claudeAgent",
            providerLabel: "Claude",
            slug: "claude-sonnet-4-6",
            shortName: "Sonnet",
            displayName: "Sonnet",
            isDefault: false,
            isFavorite: true,
            reasoningOptionID: "effort",
            efforts: [
                T3EffortOption(effort: .low, rawOptionID: "low", isDefault: false),
                T3EffortOption(effort: .medium, rawOptionID: "medium", isDefault: true),
                T3EffortOption(effort: .high, rawOptionID: "high", isDefault: false),
                T3EffortOption(effort: .max, rawOptionID: "max", isDefault: false),
            ],
            fastModeMapping: .boolean(optionID: "fastMode")
        ),
        T3CatalogModel(
            instanceId: "claudeAgent",
            driver: "claudeAgent",
            providerLabel: "Claude",
            slug: "claude-opus-4-6",
            shortName: "Opus",
            displayName: "Opus",
            isDefault: true,
            isFavorite: true,
            reasoningOptionID: "effort",
            efforts: [
                T3EffortOption(effort: .low, rawOptionID: "low", isDefault: false),
                T3EffortOption(effort: .medium, rawOptionID: "medium", isDefault: false),
                T3EffortOption(effort: .high, rawOptionID: "high", isDefault: true),
                T3EffortOption(effort: .max, rawOptionID: "max", isDefault: false),
                T3EffortOption(effort: .ultra, rawOptionID: "ultrathink", isDefault: false),
            ],
            fastModeMapping: .boolean(optionID: "fastMode")
        ),
    ]

    init(client: any T3CodeClientProtocol = T3CodeClient()) {
        self.client = client
        let initialCatalog = Self.fallbackModels
        self.orderedModels = initialCatalog
        self.supportedPresets = Self.buildSupportedPresets(from: initialCatalog)
        self.defaultTransmissionMap = Self.buildDefaultTransmissionMap(from: initialCatalog, favoritesOnly: initialCatalog)
        wireClientCallbacks()
    }

    // MARK: - AgentTarget Lifecycle

    func start() {
        wireClientCallbacks()
        client.start()
    }

    func stop() {
        client.stop()
        connected = false
    }

    func reconnect() {
        connected = false
        lastConnectionMessage = "Connecting to T3 Code…"
        publishState(message: lastConnectionMessage)
        client.reconnect()
    }

    func refreshTasks() {
        // T3 Code pushes real-time updates over orchestration.subscribeShell.
    }

    // MARK: - Effort & Model Family Stepping

    func stepEffort(from preset: ModelPreset, direction: Int) -> ModelPreset {
        guard let model = lookupCatalogModel(for: preset), !model.efforts.isEmpty else {
            return preset
        }
        let efforts = model.efforts.map(\.effort)
        let currentIndex = efforts.firstIndex(of: preset.effort)
            ?? closestEffortIndex(to: preset.effort, in: efforts)
        let delta = direction > 0 ? 1 : -1
        let nextIndex = min(max(currentIndex + delta, 0), efforts.count - 1)
        return ModelPreset(
            name: model.displayName,
            model: model.slug,
            effort: efforts[nextIndex],
            provider: model.instanceId
        )
    }

    func stepModelFamily(from preset: ModelPreset, direction: Int) -> ModelPreset {
        guard !orderedModels.isEmpty else { return preset }
        let delta = direction > 0 ? 1 : -1
        let nextIndex: Int
        if let currentIndex = orderedModels.firstIndex(where: { matches(model: $0, preset: preset) }) {
            nextIndex = min(max(currentIndex + delta, 0), orderedModels.count - 1)
        } else {
            nextIndex = delta > 0 ? 0 : orderedModels.count - 1
        }
        let targetModel = orderedModels[nextIndex]
        let efforts = targetModel.efforts.map(\.effort)
        let closestIndex = closestEffortIndex(to: preset.effort, in: efforts)
        let chosenEffort = efforts.indices.contains(closestIndex) ? efforts[closestIndex] : .medium
        return ModelPreset(
            name: targetModel.displayName,
            model: targetModel.slug,
            effort: chosenEffort,
            provider: targetModel.instanceId
        )
    }

    // MARK: - Settings Application

    func apply(
        _ update: AgentSettingsUpdate,
        to taskID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        switch makeModelSelection(for: update, taskID: taskID) {
        case let .success(selection):
            client.setModelSelection(threadID: taskID, selection: selection, completion: completion)
        case let .failure(error):
            completion(.failure(error))
        }
    }

    func makeModelSelection(
        for update: AgentSettingsUpdate,
        taskID: String
    ) -> Result<T3ModelSelection, Error> {
        let thread = threadsByID[taskID]

        if let preset = update.preset {
            let catalogModel = lookupCatalogModel(for: preset)
            let instanceId = preset.provider
                ?? catalogModel?.instanceId
                ?? thread?.modelSelection.instanceId
                ?? thread?.providerInstanceId

            let sameModelAsThread = thread != nil
                && thread?.modelSelection.model == preset.model
                && (instanceId == nil || (thread?.modelSelection.instanceId ?? thread?.providerInstanceId) == instanceId)

            var options: [T3ProviderOptionSelection] = sameModelAsThread ? (thread?.modelSelection.options ?? []) : []

            if let reasoningID = catalogModel?.reasoningOptionID,
               let rawEffort = catalogModel?.rawEffortOptionID(for: preset.effort) {
                options.removeAll { $0.id == reasoningID }
                options.append(T3ProviderOptionSelection(id: reasoningID, value: .string(rawEffort)))
            } else if catalogModel == nil {
                // Unknown model before catalog load: send standard effort option.
                options.removeAll { $0.id == "effort" }
                options.append(T3ProviderOptionSelection(id: "effort", value: .string(preset.effort.rawValue)))
            }

            if let fastMode = update.fastMode, let fastMapping = catalogModel?.fastModeMapping {
                options.removeAll { $0.id == fastMapping.optionID }
                options.append(fastMapping.optionSelection(fastMode: fastMode))
            }

            return .success(T3ModelSelection(
                instanceId: instanceId,
                model: preset.model,
                options: options.isEmpty ? nil : options
            ))
        }

        // Fast-mode-only update (no preset change)
        guard let fastMode = update.fastMode else {
            guard let thread else {
                return .failure(T3CodeClientError.unknownThread(taskID))
            }
            return .success(thread.modelSelection)
        }

        guard let thread else {
            return .failure(T3CodeClientError.unknownThread(taskID))
        }

        let instanceId = thread.modelSelection.instanceId ?? thread.providerInstanceId
        let modelSlug = thread.modelSelection.model
        let catalogModel = lookupCatalogModel(instanceId: instanceId, modelSlug: modelSlug)

        guard let fastMapping = catalogModel?.fastModeMapping else {
            let label = catalogModel?.displayName ?? modelSlug
            return .failure(T3CodeClientError.fastModeUnsupported(label))
        }

        var options = thread.modelSelection.options ?? []
        options.removeAll { $0.id == fastMapping.optionID }
        options.append(fastMapping.optionSelection(fastMode: fastMode))

        return .success(T3ModelSelection(
            instanceId: instanceId,
            model: modelSlug,
            options: options
        ))
    }

    // MARK: - Deep Link

    func taskURL(for taskID: String) -> URL? {
        guard let environmentID, !environmentID.isEmpty else {
            return URL(string: "t3code://new")
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encodedEnv = environmentID.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedTask = taskID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return URL(string: "t3code://new")
        }
        return URL(string: "t3code://threads/\(encodedEnv)/\(encodedTask)")
    }

    // MARK: - Client Event Wiring

    private func wireClientCallbacks() {
        client.onConnectionChange = { [weak self] state in
            self?.handleConnectionChange(state)
        }
        client.onConfigSnapshot = { [weak self] config in
            self?.applyConfigSnapshot(config)
        }
        client.onProvidersUpdated = { [weak self] providers in
            self?.applyProvidersUpdated(providers)
        }
        client.onSettingsUpdated = { [weak self] settings in
            self?.applySettingsUpdated(settings)
        }
        client.onShellBatch = { [weak self] events in
            self?.applyShellBatch(events)
        }
        client.onShellSnapshot = { [weak self] projects, threads, isEnrichmentOnly in
            self?.applyShellSnapshot(projects: projects, threads: threads, isEnrichmentOnly: isEnrichmentOnly)
        }
        client.onProjectUpdated = { [weak self] project in
            self?.applyProjectUpdated(project)
        }
        client.onProjectRemoved = { [weak self] projectID in
            self?.applyProjectRemoved(projectID)
        }
        client.onThreadUpdated = { [weak self] thread, location in
            self?.applyThreadUpdated(thread, location: location)
        }
        client.onThreadRemoved = { [weak self] threadID, location in
            self?.applyThreadRemoved(threadID, location: location)
        }
    }

    private func handleConnectionChange(_ state: T3ConnectionState) {
        switch state {
        case .connecting:
            connected = false
            lastConnectionMessage = "Connecting to T3 Code…"
            publishState(message: lastConnectionMessage)
        case .connected:
            connected = true
            lastConnectionMessage = nil
            publishState(message: nil)
        case let .offline(reason):
            connected = false
            lastConnectionMessage = reason
            publishState(message: reason)
        }
    }

    // MARK: - Config & Dynamic Catalog

    func applyConfigSnapshot(_ config: T3ServerConfigPayload) {
        if let envID = config.environment?.environmentId, !envID.isEmpty {
            environmentID = envID
        }
        if let providers = config.providers {
            self.providers = providers
        }
        if let settings = config.settings {
            favorites = settings.favorites ?? []
            providerModelPreferences = settings.providerModelPreferences ?? [:]
        }
        rebuildCatalog()
    }

    func applyProvidersUpdated(_ providers: [T3ServerProvider]) {
        self.providers = providers
        rebuildCatalog()
    }

    func applySettingsUpdated(_ settings: T3ServerSettingsPayload) {
        favorites = settings.favorites ?? []
        providerModelPreferences = settings.providerModelPreferences ?? [:]
        rebuildCatalog()
    }

    private func rebuildCatalog() {
        let fullCatalog = Self.extractFullCatalog(
            providers: providers,
            favorites: favorites,
            preferences: providerModelPreferences
        )

        guard !fullCatalog.isEmpty else {
            publishState(message: lastConnectionMessage)
            return
        }

        let favoriteCatalog = Self.extractFavoriteCatalog(from: fullCatalog, favorites: favorites)
        var merged: [T3CatalogModel] = []
        var seen = Set<String>()
        for model in favoriteCatalog + fullCatalog {
            let key = "\(model.instanceId)::\(model.slug)"
            if seen.insert(key).inserted {
                merged.append(model)
            }
        }

        orderedModels = merged
        supportedPresets = Self.buildSupportedPresets(from: merged)
        defaultTransmissionMap = Self.buildDefaultTransmissionMap(
            from: merged,
            favoritesOnly: favoriteCatalog.isEmpty ? merged : favoriteCatalog
        )
        publishState(message: lastConnectionMessage)
    }

    // MARK: - Shell State & Focus Tracking (Matches t3-stream-deck/src/store.ts)

    func applyShellBatch(_ events: [T3ShellEvent]) {
        guard !events.isEmpty else { return }
        let previousFocus = focusedThreadID
        var forceEmitFocus = false

        for event in events {
            switch event {
            case let .snapshot(projects, threads, isEnrichmentOnly):
                mutateForShellSnapshot(projects: projects, threads: threads, isEnrichmentOnly: isEnrichmentOnly)
                if !isEnrichmentOnly && focusedThreadID != nil {
                    forceEmitFocus = true
                }
            case let .projectUpdated(project):
                if project.deletedAt != nil {
                    projectsByID.removeValue(forKey: project.id)
                } else {
                    projectsByID[project.id] = project
                }
            case let .projectRemoved(projectID):
                projectsByID.removeValue(forKey: projectID)
            case let .threadUpdated(thread, location):
                mutateForThreadUpdated(thread, location: location)
            case let .threadRemoved(threadID, _):
                threadsByID.removeValue(forKey: threadID)
            }
        }

        ensureValidFocus()
        emitTasks()
        if focusedThreadID != previousFocus || forceEmitFocus {
            onFocusedTaskChanged?(focusedThreadID)
        }
    }

    func applyShellSnapshot(projects: [T3ProjectShell], threads: [T3ThreadShell], isEnrichmentOnly: Bool) {
        let previousFocus = focusedThreadID
        mutateForShellSnapshot(projects: projects, threads: threads, isEnrichmentOnly: isEnrichmentOnly)
        emitTasks()
        if !isEnrichmentOnly, focusedThreadID != previousFocus || focusedThreadID != nil {
            onFocusedTaskChanged?(focusedThreadID)
        }
    }

    private func mutateForShellSnapshot(projects: [T3ProjectShell], threads: [T3ThreadShell], isEnrichmentOnly: Bool) {
        if isEnrichmentOnly {
            for project in projects where project.deletedAt == nil {
                projectsByID[project.id] = project
            }
            return
        }

        projectsByID.removeAll(keepingCapacity: true)
        for project in projects where project.deletedAt == nil {
            projectsByID[project.id] = project
        }

        threadsByID.removeAll(keepingCapacity: true)
        for thread in threads where thread.deletedAt == nil && thread.archivedAt == nil {
            threadsByID[thread.id] = thread
        }

        if let mostRecent = findMostRecentlyVisitedThread() {
            focusedThreadID = mostRecent.id
            lastAppOpenedThreadID = mostRecent.id
        } else {
            ensureValidFocus()
        }
    }

    func applyProjectUpdated(_ project: T3ProjectShell) {
        if project.deletedAt != nil {
            projectsByID.removeValue(forKey: project.id)
        } else {
            projectsByID[project.id] = project
        }
        emitTasks()
    }

    func applyProjectRemoved(_ projectID: String) {
        projectsByID.removeValue(forKey: projectID)
        emitTasks()
    }

    func applyThreadUpdated(_ thread: T3ThreadShell, location: String) {
        let previousFocus = focusedThreadID
        mutateForThreadUpdated(thread, location: location)
        ensureValidFocus()
        emitTasks()
        if focusedThreadID != previousFocus {
            onFocusedTaskChanged?(focusedThreadID)
        }
    }

    private func mutateForThreadUpdated(_ thread: T3ThreadShell, location: String) {
        let prev = threadsByID[thread.id]

        if location == "archive" || thread.deletedAt != nil || thread.archivedAt != nil {
            threadsByID.removeValue(forKey: thread.id)
        } else {
            threadsByID[thread.id] = thread

            // Auto-follow when the user opens/switches a top-level thread in T3 Code
            // (opens.openedAt advances, or lastVisitedAt advances on a different thread).
            if thread.lineage?.parentThreadId == nil {
                let prevOpened = prev.map(Self.threadOpenedTimestamp) ?? 0
                let nextOpened = Self.threadOpenedTimestamp(thread)
                let prevVisited = Self.parseISO8601Millis(prev?.lastVisitedAt)
                let nextVisited = Self.parseISO8601Millis(thread.lastVisitedAt)

                let switchedByOpen = nextOpened > prevOpened
                let switchedByVisitOnDifferentThread =
                    nextVisited > prevVisited && thread.id != lastAppOpenedThreadID

                if switchedByOpen || switchedByVisitOnDifferentThread {
                    lastAppOpenedThreadID = thread.id
                    focusedThreadID = thread.id
                }
            }
        }
    }

    func applyThreadRemoved(_ threadID: String, location: String) {
        let previousFocus = focusedThreadID
        threadsByID.removeValue(forKey: threadID)
        ensureValidFocus()
        emitTasks()
        if focusedThreadID != previousFocus {
            onFocusedTaskChanged?(focusedThreadID)
        }
    }

    private func findMostRecentlyVisitedThread() -> T3ThreadShell? {
        var best: T3ThreadShell?
        var bestVisit: Int64 = -1
        var bestUpdated: Int64 = -1

        for thread in threadsByID.values {
            guard thread.deletedAt == nil, thread.archivedAt == nil, thread.lineage?.parentThreadId == nil else {
                continue
            }
            let visit = Self.threadVisitTimestamp(thread)
            let updated = Self.parseISO8601Millis(thread.updatedAt)

            if visit > bestVisit || (visit == bestVisit && updated > bestUpdated) {
                bestVisit = visit
                bestUpdated = updated
                best = thread
            }
        }
        return best
    }

    private func ensureValidFocus() {
        if let focusedThreadID,
           let existing = threadsByID[focusedThreadID],
           existing.deletedAt == nil,
           existing.archivedAt == nil {
            return
        }
        let next = findMostRecentlyVisitedThread()
        focusedThreadID = next?.id
        if let id = next?.id {
            lastAppOpenedThreadID = id
        }
    }

    private func emitTasks() {
        var ranked: [(thread: T3ThreadShell, visitMs: Int64, updatedMs: Int64)] = []
        ranked.reserveCapacity(threadsByID.count)
        for thread in threadsByID.values {
            guard thread.deletedAt == nil, thread.archivedAt == nil, thread.lineage?.parentThreadId == nil else {
                continue
            }
            ranked.append((
                thread: thread,
                visitMs: Self.threadVisitTimestamp(thread),
                updatedMs: Self.parseISO8601Millis(thread.updatedAt)
            ))
        }

        ranked.sort { lhs, rhs in
            if lhs.visitMs != rhs.visitMs { return lhs.visitMs > rhs.visitMs }
            if lhs.updatedMs != rhs.updatedMs { return lhs.updatedMs > rhs.updatedMs }
            return lhs.thread.id < rhs.thread.id
        }

        let tasks = ranked.map { entry -> AgentTask in
            let title = entry.thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let workspace = projectsByID[entry.thread.projectId]?.title ?? "T3 Code"
            let tsMs = max(entry.visitMs, entry.updatedMs)
            return AgentTask(
                id: entry.thread.id,
                title: title.isEmpty ? "Untitled" : title,
                workspace: workspace,
                updatedAt: Int(tsMs / 1000)
            )
        }

        guard tasks != lastEmittedTasks else { return }
        lastEmittedTasks = tasks
        onTasksChanged?(tasks)
    }

    private func publishState(message: String?) {
        onStateChanged?(AgentTargetState(
            discoveryConnected: connected,
            controlConnected: connected,
            message: message
        ))
    }

    // MARK: - Lookup Helpers

    private func matches(model: T3CatalogModel, preset: ModelPreset) -> Bool {
        if let provider = preset.provider {
            return model.instanceId == provider && model.slug == preset.model
        }
        return model.slug == preset.model
    }

    private func lookupCatalogModel(for preset: ModelPreset) -> T3CatalogModel? {
        if let provider = preset.provider,
           let exact = orderedModels.first(where: { $0.instanceId == provider && $0.slug == preset.model }) {
            return exact
        }
        return orderedModels.first(where: { $0.slug == preset.model })
    }

    private func lookupCatalogModel(instanceId: String?, modelSlug: String) -> T3CatalogModel? {
        if let instanceId,
           let exact = orderedModels.first(where: { $0.instanceId == instanceId && $0.slug == modelSlug }) {
            return exact
        }
        return orderedModels.first(where: { $0.slug == modelSlug })
    }

    private func closestEffortIndex(to effort: ReasoningEffort, in efforts: [ReasoningEffort]) -> Int {
        guard !efforts.isEmpty else { return 0 }
        let targetRank = ReasoningEffort.allCases.firstIndex(of: effort) ?? 0
        var bestIndex = 0
        var bestDistance = Int.max
        for (index, candidate) in efforts.enumerated() {
            let rank = ReasoningEffort.allCases.firstIndex(of: candidate) ?? 0
            let distance = abs(rank - targetRank)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    // MARK: - Static Timestamp & Sorting Helpers

    static func threadOpenedTimestamp(_ thread: T3ThreadShell) -> Int64 {
        guard let openedAt = thread.opens?.openedAt, openedAt.isFinite, openedAt > 0 else { return 0 }
        return Int64(openedAt)
    }

    static func threadVisitTimestamp(_ thread: T3ThreadShell) -> Int64 {
        let openedAt = threadOpenedTimestamp(thread)
        let visitedAt = parseISO8601Millis(thread.lastVisitedAt)
        return max(openedAt, visitedAt)
    }

    /// Zero-allocation RFC3339 / ISO-8601 timestamp parser (YYYY-MM-DDTHH:MM:SS[.fff][Z|±HH:MM]).
    /// Avoids ICU `ISO8601DateFormatter` allocation inside thread-list sorting hot paths.
    static func parseISO8601Millis(_ string: String?) -> Int64 {
        guard let string, string.utf8.count >= 19 else { return 0 }
        let bytes = Array(string.utf8)
        let count = bytes.count

        @inline(__always)
        func digit(_ index: Int) -> Int64? {
            guard index < count else { return nil }
            let b = bytes[index]
            guard b >= 48 && b <= 57 else { return nil }
            return Int64(b - 48)
        }

        @inline(__always)
        func twoDigits(_ start: Int) -> Int64? {
            guard let a = digit(start), let b = digit(start + 1) else { return nil }
            return a * 10 + b
        }

        guard let y1 = digit(0), let y2 = digit(1), let y3 = digit(2), let y4 = digit(3),
              bytes[4] == 45, // '-'
              let month = twoDigits(5),
              bytes[7] == 45, // '-'
              let day = twoDigits(8),
              (bytes[10] == 84 || bytes[10] == 116 || bytes[10] == 32), // 'T', 't', ' '
              let hour = twoDigits(11),
              bytes[13] == 58, // ':'
              let minute = twoDigits(14),
              bytes[16] == 58, // ':'
              let second = twoDigits(17) else {
            return 0
        }

        let year = y1 * 1000 + y2 * 100 + y3 * 10 + y4
        guard month >= 1 && month <= 12,
              day >= 1 && day <= 31,
              hour <= 23, minute <= 59, second <= 60 else {
            return 0
        }

        var idx = 19
        var millis: Int64 = 0
        if idx < count && bytes[idx] == 46 { // '.'
            idx += 1
            var scale: Int64 = 100
            while idx < count, let d = digit(idx) {
                if scale > 0 {
                    millis += d * scale
                    scale /= 10
                }
                idx += 1
            }
        }

        var tzOffsetSeconds: Int64 = 0
        if idx < count {
            let tz = bytes[idx]
            if tz == 90 || tz == 122 { // 'Z' or 'z'
                tzOffsetSeconds = 0
            } else if tz == 43 || tz == 45 { // '+' or '-'
                let sign: Int64 = tz == 43 ? 1 : -1
                idx += 1
                if let tzH = twoDigits(idx) {
                    idx += 2
                    if idx < count && bytes[idx] == 58 { idx += 1 }
                    let tzM = twoDigits(idx) ?? 0
                    tzOffsetSeconds = sign * (tzH * 3600 + tzM * 60)
                }
            }
        }

        // Howard Hinnant's civil-to-days algorithm (days since 1970-01-01).
        let adjYear = month <= 2 ? year - 1 : year
        let era = (adjYear >= 0 ? adjYear : adjYear - 399) / 400
        let yoe = adjYear - era * 400
        let adjMonth = month > 2 ? month - 3 : month + 9
        let doy = (153 * adjMonth + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468

        let totalSeconds = days * 86400 + hour * 3600 + minute * 60 + second - tzOffsetSeconds
        return totalSeconds * 1000 + millis
    }

    static func compareThreads(_ lhs: T3ThreadShell, _ rhs: T3ThreadShell) -> Bool {
        let visitA = threadVisitTimestamp(lhs)
        let visitB = threadVisitTimestamp(rhs)
        if visitA != visitB { return visitA > visitB }

        let updatedA = parseISO8601Millis(lhs.updatedAt)
        let updatedB = parseISO8601Millis(rhs.updatedAt)
        if updatedA != updatedB { return updatedA > updatedB }

        return lhs.id < rhs.id
    }

    // MARK: - Static Catalog & Map Builders

    static func shortModelLabel(slug: String, name: String?, shortName: String?) -> String {
        if let shortName {
            let trimmed = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        var label = slug
        if label.hasPrefix("claude-") {
            label = String(label.dropFirst("claude-".count))
        } else if label.hasPrefix("openai/") {
            label = String(label.dropFirst("openai/".count))
        }
        return label.replacingOccurrences(of: "-", with: " ")
    }

    static func providerDisplayLabel(_ provider: T3ServerProvider) -> String {
        if let display = provider.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty {
            return display
        }
        if let badge = provider.badgeLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !badge.isEmpty {
            return badge
        }
        let driver = provider.driver.lowercased()
        let id = provider.instanceId.lowercased()
        if id.contains("antigravity") || driver.contains("antigravity") { return "Antigravity" }
        if driver.contains("claude") { return "Claude" }
        if driver.contains("codex") { return "Codex" }
        if driver.contains("opencode") { return "OpenCode" }
        if driver.contains("cursor") { return "Cursor" }
        if driver.contains("grok") { return "Grok" }
        return driver.prefix(1).uppercased() + driver.dropFirst()
    }

    static func findReasoningDescriptor(
        in descriptors: [T3ProviderOptionDescriptor]?
    ) -> T3ProviderOptionDescriptor? {
        guard let descriptors, !descriptors.isEmpty else { return nil }
        if let byRole = descriptors.first(where: {
            $0.type == "select" && $0.role == "reasoning" && !($0.options ?? []).isEmpty
        }) {
            return byRole
        }
        return descriptors.first(where: { descriptor in
            guard descriptor.type == "select", !(descriptor.options ?? []).isEmpty else { return false }
            let haystack = "\(descriptor.id) \(descriptor.label)".lowercased()
            return haystack.contains("effort")
                || haystack.contains("reason")
                || haystack.contains("thought")
                || haystack.contains("think")
                || haystack.contains("variant")
        })
    }

    static func findFastModeMapping(
        in descriptors: [T3ProviderOptionDescriptor]?
    ) -> T3FastModeMapping? {
        guard let descriptors, !descriptors.isEmpty else { return nil }

        if let boolDesc = descriptors.first(where: { descriptor in
            guard descriptor.type == "boolean" else { return false }
            let id = descriptor.id.lowercased()
            return id == "fastmode" || id == "fast_mode" || id == "fast"
        }) {
            return .boolean(optionID: boolDesc.id)
        }

        if let tierDesc = descriptors.first(where: { descriptor in
            guard descriptor.type == "select", !(descriptor.options ?? []).isEmpty else { return false }
            let id = descriptor.id.lowercased()
            return id == "servicetier" || id == "service_tier" || id == "speed"
        }), let choices = tierDesc.options {
            let fastChoice = choices.first(where: { $0.id.lowercased() == "priority" })
                ?? choices.first(where: { $0.id.lowercased() == "fast" })
                ?? choices.first(where: { $0.id.lowercased().contains("fast") })
            let standardChoice = choices.first(where: { $0.id.lowercased() == "default" })
                ?? choices.first(where: { $0.id.lowercased() == "standard" })
                ?? choices.first(where: { $0.id.lowercased() == "normal" })
                ?? choices.first(where: { $0.id != fastChoice?.id })

            if let fastChoice, let standardChoice {
                return .select(
                    optionID: tierDesc.id,
                    fastValue: fastChoice.id,
                    standardValue: standardChoice.id
                )
            }
        }

        return nil
    }

    static func mapReasoningEffort(_ optionID: String) -> ReasoningEffort? {
        switch optionID.lowercased() {
        case "low":
            return .low
        case "medium", "med":
            return .medium
        case "high":
            return .high
        case "xhigh", "extra_high", "extra-high":
            return .xhigh
        case "max":
            return .max
        case "ultra", "ultrathink":
            return .ultra
        default:
            return nil
        }
    }

    static func extractFullCatalog(
        providers: [T3ServerProvider],
        favorites: [T3ModelFavorite],
        preferences: [String: T3ProviderModelPreference]
    ) -> [T3CatalogModel] {
        let favKeys = Set(favorites.map { "\($0.provider)::\($0.model)" })
        var rawEntries: [(
            instanceId: String,
            driver: String,
            providerLabel: String,
            slug: String,
            shortName: String,
            isDefault: Bool,
            isFavorite: Bool,
            reasoningOptionID: String?,
            efforts: [T3EffortOption],
            fastModeMapping: T3FastModeMapping?
        )] = []

        for provider in providers {
            guard provider.enabled, provider.status == "ready", !provider.models.isEmpty else { continue }
            let providerLabel = providerDisplayLabel(provider)
            let pref = preferences[provider.instanceId]
            let hidden = Set(pref?.hiddenModels ?? [])
            var orderIndex: [String: Int] = [:]
            for (idx, slug) in (pref?.modelOrder ?? []).enumerated() {
                orderIndex[slug] = idx
            }

            let visibleModels = provider.models.enumerated()
                .filter { _, model in
                    model.isLegacy != true && !hidden.contains(model.slug)
                }
                .sorted { lhs, rhs in
                    let ordA = orderIndex[lhs.element.slug]
                    let ordB = orderIndex[rhs.element.slug]
                    if let ordA, let ordB { return ordA < ordB }
                    if ordA != nil { return true }
                    if ordB != nil { return false }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)

            for model in visibleModels {
                let isFav = favKeys.contains("\(provider.instanceId)::\(model.slug)")
                    || favKeys.contains("\(provider.driver)::\(model.slug)")
                let shortName = shortModelLabel(slug: model.slug, name: model.name, shortName: model.shortName)
                let reasoningDesc = findReasoningDescriptor(in: model.capabilities?.optionDescriptors)
                let fastMapping = findFastModeMapping(in: model.capabilities?.optionDescriptors)

                var efforts: [T3EffortOption] = []
                var seenEfforts = Set<ReasoningEffort>()
                for choice in reasoningDesc?.options ?? [] {
                    if let mapped = mapReasoningEffort(choice.id), seenEfforts.insert(mapped).inserted {
                        efforts.append(T3EffortOption(
                            effort: mapped,
                            rawOptionID: choice.id,
                            isDefault: choice.isDefault == true
                        ))
                    }
                }
                if efforts.isEmpty {
                    efforts = [T3EffortOption(effort: .medium, rawOptionID: nil, isDefault: true)]
                }

                rawEntries.append((
                    instanceId: provider.instanceId,
                    driver: provider.driver,
                    providerLabel: providerLabel,
                    slug: model.slug,
                    shortName: shortName,
                    isDefault: model.isDefault == true,
                    isFavorite: isFav,
                    reasoningOptionID: reasoningDesc?.id,
                    efforts: efforts,
                    fastModeMapping: fastMapping
                ))
            }
        }

        // Disambiguate duplicate short names across distinct provider instances
        var shortNameCounts: [String: Int] = [:]
        for entry in rawEntries {
            shortNameCounts[entry.shortName, default: 0] += 1
        }

        return rawEntries.map { entry in
            let displayName = (shortNameCounts[entry.shortName] ?? 0) > 1
                ? "\(entry.shortName) (\(entry.providerLabel))"
                : entry.shortName
            return T3CatalogModel(
                instanceId: entry.instanceId,
                driver: entry.driver,
                providerLabel: entry.providerLabel,
                slug: entry.slug,
                shortName: entry.shortName,
                displayName: displayName,
                isDefault: entry.isDefault,
                isFavorite: entry.isFavorite,
                reasoningOptionID: entry.reasoningOptionID,
                efforts: entry.efforts,
                fastModeMapping: entry.fastModeMapping
            )
        }
    }

    static func extractFavoriteCatalog(
        from fullCatalog: [T3CatalogModel],
        favorites: [T3ModelFavorite]
    ) -> [T3CatalogModel] {
        guard !favorites.isEmpty else { return [] }
        var byExact: [String: T3CatalogModel] = [:]
        for entry in fullCatalog {
            byExact["\(entry.instanceId)::\(entry.slug)"] = entry
        }

        var ordered: [T3CatalogModel] = []
        var seen = Set<String>()
        for fav in favorites {
            let exactKey = "\(fav.provider)::\(fav.model)"
            let matched = byExact[exactKey]
                ?? fullCatalog.first(where: { $0.driver == fav.provider && $0.slug == fav.model })
            guard let matched else { continue }
            let dedupeKey = "\(matched.instanceId)::\(matched.slug)"
            guard seen.insert(dedupeKey).inserted else { continue }
            ordered.append(matched)
        }
        return ordered
    }

    static func buildSupportedPresets(from catalog: [T3CatalogModel]) -> [ModelPreset] {
        catalog.flatMap { model in
            model.efforts.map { option in
                ModelPreset(
                    name: model.displayName,
                    model: model.slug,
                    effort: option.effort,
                    provider: model.instanceId
                )
            }
        }
    }

    static func buildDefaultTransmissionMap(
        from fullCatalog: [T3CatalogModel],
        favoritesOnly primary: [T3CatalogModel]
    ) -> TransmissionMap {
        let source = primary.isEmpty ? fullCatalog : primary
        let selectedModels = Array(source.prefix(6))
        guard !selectedModels.isEmpty else {
            let fallback = fallbackModels
            return buildDefaultTransmissionMap(from: fallback, favoritesOnly: fallback)
        }

        // Distribute 6 forward gears across up to 6 primary models.
        let modelCount = selectedModels.count
        let baseSlots = 6 / modelCount
        let extraSlots = 6 % modelCount

        var forward: [ModelPreset] = []
        for (index, model) in selectedModels.enumerated() {
            let slots = baseSlots + (index < extraSlots ? 1 : 0)
            let chosenEfforts = pickEfforts(for: model, count: slots)
            for effort in chosenEfforts {
                forward.append(ModelPreset(
                    name: model.displayName,
                    model: model.slug,
                    effort: effort,
                    provider: model.instanceId
                ))
            }
        }

        // Reverse gear: review-oriented high/max preset on the top primary model.
        let reviewModel = selectedModels[0]
        let reviewEffort = preferredReviewEffort(for: reviewModel)
        let reverse = ModelPreset(
            name: reviewModel.displayName,
            model: reviewModel.slug,
            effort: reviewEffort,
            provider: reviewModel.instanceId
        )

        return TransmissionMap(forward: forward, reverse: reverse)
    }

    private static func pickEfforts(for model: T3CatalogModel, count: Int) -> [ReasoningEffort] {
        let efforts = model.efforts.map(\.effort)
        guard !efforts.isEmpty else { return Array(repeating: .medium, count: count) }

        if count == 1 {
            if let def = model.efforts.first(where: \.isDefault)?.effort {
                return [def]
            }
            if efforts.contains(.high) { return [.high] }
            return [efforts[efforts.count / 2]]
        }

        if efforts.count == 1 {
            return Array(repeating: efforts[0], count: count)
        }

        // Evenly sample across the model's supported efforts from low -> high.
        var picked: [ReasoningEffort] = []
        for step in 0..<count {
            let ratio = Double(step) / Double(count - 1)
            let idx = Int(round(ratio * Double(efforts.count - 1)))
            picked.append(efforts[min(max(idx, 0), efforts.count - 1)])
        }
        return picked
    }

    private static func preferredReviewEffort(for model: T3CatalogModel) -> ReasoningEffort {
        let efforts = model.efforts.map(\.effort)
        if efforts.contains(.max) { return .max }
        if efforts.contains(.xhigh) { return .xhigh }
        if efforts.contains(.high) { return .high }
        return efforts.last ?? .medium
    }
}
