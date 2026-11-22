import Darwin
import Foundation
import os

private let t3Log = Logger(subsystem: "com.metaember.agent-transmission", category: "T3Code")

// MARK: - Protocol Models

struct T3ServerRuntimeState: Codable, Equatable, Sendable {
    let version: Int?
    let pid: Int?
    let port: Int?
    let origin: String
    let serverVersion: String?
}

struct T3StoredSession: Codable, Equatable, Sendable {
    let sessionId: String
    let token: String
    let createdAt: String
}

enum T3OptionValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
            return
        }
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        if let numberValue = try? container.decode(Double.self) {
            self = .number(numberValue)
            return
        }
        // Tolerate unknown/complex option values without failing the parent payload.
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var jsonValue: Any {
        switch self {
        case let .string(value): value
        case let .bool(value): value
        case let .number(value): value
        case .null: NSNull()
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }
}

struct T3ProviderOptionSelection: Codable, Equatable, Sendable {
    let id: String
    let value: T3OptionValue
}

struct T3ModelSelection: Codable, Equatable, Sendable {
    let instanceId: String?
    let provider: String?
    let model: String
    let options: [T3ProviderOptionSelection]?

    init(
        instanceId: String? = nil,
        provider: String? = nil,
        model: String,
        options: [T3ProviderOptionSelection]? = nil
    ) {
        self.instanceId = instanceId
        self.provider = provider
        self.model = model
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case instanceId
        case provider
        case model
        case options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instanceId = try container.decodeIfPresent(String.self, forKey: .instanceId)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        model = (try? container.decode(String.self, forKey: .model)) ?? ""

        if let list = try? container.decodeIfPresent([T3ProviderOptionSelection].self, forKey: .options) {
            options = list.filter { $0.value != .null }
        } else if let dict = try? container.decodeIfPresent([String: T3OptionValue].self, forKey: .options) {
            options = dict.keys.sorted().compactMap { key in
                guard let val = dict[key], val != .null else { return nil }
                return T3ProviderOptionSelection(id: key, value: val)
            }
        } else {
            options = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(instanceId, forKey: .instanceId)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(options, forKey: .options)
    }

    func toJSONDictionary() -> [String: Any] {
        var payload: [String: Any] = ["model": model]
        if let instanceId { payload["instanceId"] = instanceId }
        if let provider { payload["provider"] = provider }
        if let options {
            payload["options"] = options.map { option in
                ["id": option.id, "value": option.value.jsonValue] as [String: Any]
            }
        }
        return payload
    }
}

struct T3ProviderOptionChoice: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let description: String?
    let isDefault: Bool?

    init(id: String, label: String, description: String? = nil, isDefault: Bool? = nil) {
        self.id = id
        self.label = label
        self.description = description
        self.isDefault = isDefault
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? id
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        isDefault = try? container.decodeIfPresent(Bool.self, forKey: .isDefault)
    }
}

struct T3ProviderOptionDescriptor: Codable, Equatable, Sendable {
    let id: String
    let label: String
    let description: String?
    let type: String
    let options: [T3ProviderOptionChoice]?
    let currentValue: T3OptionValue?
    let role: String?

    init(
        id: String,
        label: String,
        description: String? = nil,
        type: String,
        options: [T3ProviderOptionChoice]? = nil,
        currentValue: T3OptionValue? = nil,
        role: String? = nil
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.type = type
        self.options = options
        self.currentValue = currentValue
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? id
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? "select"
        options = try? container.decodeIfPresent([T3ProviderOptionChoice].self, forKey: .options)
        currentValue = try? container.decodeIfPresent(T3OptionValue.self, forKey: .currentValue)
        role = try? container.decodeIfPresent(String.self, forKey: .role)
    }
}

struct T3ModelCapabilities: Codable, Equatable, Sendable {
    let optionDescriptors: [T3ProviderOptionDescriptor]?
}

struct T3ServerProviderModel: Codable, Equatable, Sendable {
    let slug: String
    let name: String
    let shortName: String?
    let subProvider: String?
    let isCustom: Bool?
    let isDefault: Bool?
    let isLegacy: Bool?
    let capabilities: T3ModelCapabilities?

    init(
        slug: String,
        name: String,
        shortName: String? = nil,
        subProvider: String? = nil,
        isCustom: Bool? = nil,
        isDefault: Bool? = nil,
        isLegacy: Bool? = nil,
        capabilities: T3ModelCapabilities? = nil
    ) {
        self.slug = slug
        self.name = name
        self.shortName = shortName
        self.subProvider = subProvider
        self.isCustom = isCustom
        self.isDefault = isDefault
        self.isLegacy = isLegacy
        self.capabilities = capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? slug
        shortName = try? container.decodeIfPresent(String.self, forKey: .shortName)
        subProvider = try? container.decodeIfPresent(String.self, forKey: .subProvider)
        isCustom = try? container.decodeIfPresent(Bool.self, forKey: .isCustom)
        isDefault = try? container.decodeIfPresent(Bool.self, forKey: .isDefault)
        isLegacy = try? container.decodeIfPresent(Bool.self, forKey: .isLegacy)
        capabilities = try? container.decodeIfPresent(T3ModelCapabilities.self, forKey: .capabilities)
    }
}

struct T3ServerProvider: Codable, Equatable, Sendable {
    let instanceId: String
    let driver: String
    let displayName: String?
    let accentColor: String?
    let badgeLabel: String?
    let enabled: Bool
    let installed: Bool?
    let status: String
    let models: [T3ServerProviderModel]

    init(
        instanceId: String,
        driver: String,
        displayName: String? = nil,
        accentColor: String? = nil,
        badgeLabel: String? = nil,
        enabled: Bool,
        installed: Bool? = nil,
        status: String,
        models: [T3ServerProviderModel]
    ) {
        self.instanceId = instanceId
        self.driver = driver
        self.displayName = displayName
        self.accentColor = accentColor
        self.badgeLabel = badgeLabel
        self.enabled = enabled
        self.installed = installed
        self.status = status
        self.models = models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instanceId = try container.decode(String.self, forKey: .instanceId)
        driver = (try? container.decodeIfPresent(String.self, forKey: .driver)) ?? instanceId
        displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        accentColor = try? container.decodeIfPresent(String.self, forKey: .accentColor)
        badgeLabel = try? container.decodeIfPresent(String.self, forKey: .badgeLabel)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        installed = try? container.decodeIfPresent(Bool.self, forKey: .installed)
        status = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? "ready"
        models = (try? container.decodeIfPresent([T3ServerProviderModel].self, forKey: .models)) ?? []
    }
}

struct T3ModelFavorite: Codable, Equatable, Sendable {
    let provider: String
    let model: String
}

struct T3ProviderModelPreference: Codable, Equatable, Sendable {
    let modelOrder: [String]?
    let hiddenModels: [String]?
}

struct T3ServerSettingsPayload: Codable, Equatable, Sendable {
    let favorites: [T3ModelFavorite]?
    let providerModelPreferences: [String: T3ProviderModelPreference]?
}

struct T3EnvironmentInfo: Codable, Equatable, Sendable {
    let environmentId: String
    let label: String?
}

struct T3ServerConfigPayload: Codable, Equatable, Sendable {
    let environment: T3EnvironmentInfo?
    let providers: [T3ServerProvider]?
    let settings: T3ServerSettingsPayload?
}

struct T3ProjectShell: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let workspaceRoot: String?
    let pinnedAt: String?
    let archivedAt: String?
    let deletedAt: String?

    init(
        id: String,
        title: String,
        workspaceRoot: String? = nil,
        pinnedAt: String? = nil,
        archivedAt: String? = nil,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.workspaceRoot = workspaceRoot
        self.pinnedAt = pinnedAt
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        workspaceRoot = try? container.decodeIfPresent(String.self, forKey: .workspaceRoot)
        pinnedAt = try? container.decodeIfPresent(String.self, forKey: .pinnedAt)
        archivedAt = try? container.decodeIfPresent(String.self, forKey: .archivedAt)
        deletedAt = try? container.decodeIfPresent(String.self, forKey: .deletedAt)
    }
}

struct T3ThreadOpens: Codable, Equatable, Sendable {
    let openedAt: Double?
    let score: Double?
}

struct T3ThreadLineage: Codable, Equatable, Sendable {
    let parentThreadId: String?
    let relationshipToParent: String?
}

struct T3ThreadShell: Codable, Equatable, Sendable {
    let id: String
    let projectId: String
    let title: String
    let providerInstanceId: String
    let modelSelection: T3ModelSelection
    let status: String?
    let activeRunId: String?
    let latestRunId: String?
    let lineage: T3ThreadLineage?
    let createdAt: String?
    let updatedAt: String
    let archivedAt: String?
    let settledOverride: String?
    let settledAt: String?
    let snoozedUntil: String?
    let pinnedAt: String?
    let lastVisitedAt: String?
    let opens: T3ThreadOpens?
    let deletedAt: String?

    init(
        id: String,
        projectId: String,
        title: String,
        providerInstanceId: String,
        modelSelection: T3ModelSelection,
        status: String? = nil,
        activeRunId: String? = nil,
        latestRunId: String? = nil,
        lineage: T3ThreadLineage? = nil,
        createdAt: String? = nil,
        updatedAt: String,
        archivedAt: String? = nil,
        settledOverride: String? = nil,
        settledAt: String? = nil,
        snoozedUntil: String? = nil,
        pinnedAt: String? = nil,
        lastVisitedAt: String? = nil,
        opens: T3ThreadOpens? = nil,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.providerInstanceId = providerInstanceId
        self.modelSelection = modelSelection
        self.status = status
        self.activeRunId = activeRunId
        self.latestRunId = latestRunId
        self.lineage = lineage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.settledOverride = settledOverride
        self.settledAt = settledAt
        self.snoozedUntil = snoozedUntil
        self.pinnedAt = pinnedAt
        self.lastVisitedAt = lastVisitedAt
        self.opens = opens
        self.deletedAt = deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectId = (try? container.decodeIfPresent(String.self, forKey: .projectId)) ?? ""
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        providerInstanceId = (try? container.decodeIfPresent(String.self, forKey: .providerInstanceId)) ?? ""
        modelSelection = (try? container.decodeIfPresent(T3ModelSelection.self, forKey: .modelSelection))
            ?? T3ModelSelection(instanceId: nil, model: "")
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        activeRunId = try? container.decodeIfPresent(String.self, forKey: .activeRunId)
        latestRunId = try? container.decodeIfPresent(String.self, forKey: .latestRunId)
        lineage = try? container.decodeIfPresent(T3ThreadLineage.self, forKey: .lineage)
        createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = (try? container.decodeIfPresent(String.self, forKey: .updatedAt)) ?? ""
        archivedAt = try? container.decodeIfPresent(String.self, forKey: .archivedAt)
        settledOverride = try? container.decodeIfPresent(String.self, forKey: .settledOverride)
        settledAt = try? container.decodeIfPresent(String.self, forKey: .settledAt)
        snoozedUntil = try? container.decodeIfPresent(String.self, forKey: .snoozedUntil)
        pinnedAt = try? container.decodeIfPresent(String.self, forKey: .pinnedAt)
        lastVisitedAt = try? container.decodeIfPresent(String.self, forKey: .lastVisitedAt)
        opens = try? container.decodeIfPresent(T3ThreadOpens.self, forKey: .opens)
        deletedAt = try? container.decodeIfPresent(String.self, forKey: .deletedAt)
    }
}

enum T3ShellEvent: Equatable, Sendable {
    case snapshot(projects: [T3ProjectShell], threads: [T3ThreadShell], isEnrichmentOnly: Bool)
    case projectUpdated(T3ProjectShell)
    case projectRemoved(String)
    case threadUpdated(T3ThreadShell, location: String)
    case threadRemoved(String, location: String)
}

enum T3ConnectionState: Equatable, Sendable {
    case connecting
    case connected(origin: String)
    case offline(reason: String)
}

// MARK: - Errors

enum T3CodeClientError: LocalizedError, Equatable {
    case notConnected
    case cliNotFound(String)
    case sessionIssueFailed(String)
    case ticketRequestFailed(Int)
    case invalidTicketResponse
    case invalidWebSocketURL
    case rpcTimeout(String)
    case rpcFailure(String)
    case unknownThread(String)
    case fastModeUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to T3 Code"
        case let .cliNotFound(path):
            "T3 Code CLI not found at \(path)"
        case let .sessionIssueFailed(detail):
            "Failed to issue T3 Code session: \(detail)"
        case let .ticketRequestFailed(status):
            "T3 Code WebSocket ticket failed (HTTP \(status))"
        case .invalidTicketResponse:
            "T3 Code WebSocket ticket response missing ticket"
        case .invalidWebSocketURL:
            "Invalid T3 Code WebSocket URL"
        case let .rpcTimeout(tag):
            "T3 Code RPC timed out: \(tag)"
        case let .rpcFailure(detail):
            "T3 Code rejected the update: \(detail)"
        case let .unknownThread(id):
            "T3 Code thread not found: \(id)"
        case let .fastModeUnsupported(model):
            "\(model) does not expose a Fast mode option"
        }
    }
}

// MARK: - Client Protocol

protocol T3CodeClientProtocol: AnyObject {
    var onConnectionChange: ((T3ConnectionState) -> Void)? { get set }
    var onConfigSnapshot: ((T3ServerConfigPayload) -> Void)? { get set }
    var onProvidersUpdated: (([T3ServerProvider]) -> Void)? { get set }
    var onSettingsUpdated: ((T3ServerSettingsPayload) -> Void)? { get set }
    var onShellBatch: (([T3ShellEvent]) -> Void)? { get set }
    var onShellSnapshot: (([T3ProjectShell], [T3ThreadShell], Bool) -> Void)? { get set }
    var onProjectUpdated: ((T3ProjectShell) -> Void)? { get set }
    var onProjectRemoved: ((String) -> Void)? { get set }
    var onThreadUpdated: ((T3ThreadShell, String) -> Void)? { get set }
    var onThreadRemoved: ((String, String) -> Void)? { get set }

    func start()
    func stop()
    func reconnect()
    func refreshConfig()
    func setModelSelection(
        threadID: String,
        selection: T3ModelSelection,
        completion: @escaping (Result<Void, Error>) -> Void
    )
}

extension T3CodeClientProtocol {
    var onShellBatch: (([T3ShellEvent]) -> Void)? {
        get { nil }
        set {}
    }
}

// MARK: - Weak URLSession Delegate Proxy

private final class T3WebSocketDelegateProxy: NSObject, URLSessionWebSocketDelegate {
    weak var owner: T3CodeClient?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        owner?.handleWebSocketDidOpen(webSocketTask)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        owner?.handleWebSocketDidClose(webSocketTask, closeCode: closeCode)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let webSocketTask = task as? URLSessionWebSocketTask, let error else { return }
        owner?.handleWebSocketDidFail(webSocketTask, error: error)
    }
}

// MARK: - Native T3 Code Client

final class T3CodeClient: T3CodeClientProtocol {
    typealias JSON = [String: Any]
    typealias RpcCompletion = (Result<Any?, Error>) -> Void
    typealias StreamHandler = ([Any]) -> Void

    static let orchestrationProtocolVersion = 2
    static let reconnectDelays: [TimeInterval] = [1, 2, 4, 8, 10]
    static let pingInterval: TimeInterval = 25
    static let rpcTimeout: TimeInterval = 15
    static let sessionLabel = "Agent Transmission"
    static let sessionTTL = "365d"

    var onConnectionChange: ((T3ConnectionState) -> Void)?
    var onConfigSnapshot: ((T3ServerConfigPayload) -> Void)?
    var onProvidersUpdated: (([T3ServerProvider]) -> Void)?
    var onSettingsUpdated: ((T3ServerSettingsPayload) -> Void)?
    var onShellBatch: (([T3ShellEvent]) -> Void)?
    var onShellSnapshot: (([T3ProjectShell], [T3ThreadShell], Bool) -> Void)?
    var onProjectUpdated: ((T3ProjectShell) -> Void)?
    var onProjectRemoved: ((String) -> Void)?
    var onThreadUpdated: ((T3ThreadShell, String) -> Void)?
    var onThreadRemoved: ((String, String) -> Void)?

    private let t3Home: String
    private let t3Bin: String
    private let sessionFilePath: String
    private let queue = DispatchQueue(label: "AgentTransmission.T3CodeClient")
    private let authQueue = DispatchQueue(label: "AgentTransmission.T3CodeAuth", qos: .userInitiated)
    private let delegateProxy = T3WebSocketDelegateProxy()
    private let urlSession: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var isSocketOpen = false
    private var stopped = true
    private var connecting = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    private var connectTimeoutWorkItem: DispatchWorkItem?

    private var nextRequestID = 1
    private var pendingCalls: [String: (completion: RpcCompletion, timeout: DispatchWorkItem)] = [:]
    private var streamHandlers: [String: StreamHandler] = [:]
    private var currentOrigin: String?

    /// Test seams: allow deterministic protocol unit tests without opening a real socket.
    var sendTextOverride: ((String) -> Void)?
    var deliverCallbacksSynchronously = false

    init(
        t3Home: String? = nil,
        t3Bin: String? = nil,
        sessionFilePath: String? = nil
    ) {
        let resolvedHome = t3Home ?? Self.defaultT3Home()
        self.t3Home = resolvedHome
        self.t3Bin = t3Bin ?? Self.defaultT3Bin(t3Home: resolvedHome)
        self.sessionFilePath = sessionFilePath ?? Self.defaultSessionFilePath()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        self.urlSession = URLSession(configuration: configuration, delegate: delegateProxy, delegateQueue: nil)
        self.delegateProxy.owner = self
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    // MARK: - Environment & Discovery

    static func defaultT3Home(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let envHome = environment["T3CODE_HOME"], !envHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envHome
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3")
            .path
    }

    static func defaultT3Bin(
        t3Home: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let envBin = environment["T3CODE_CLI_PATH"], !envBin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envBin
        }
        let home = t3Home ?? defaultT3Home(environment: environment)
        return URL(fileURLWithPath: home).appendingPathComponent("bin/t3").path
    }

    static func defaultSessionFilePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-transmission/session.json")
            .path
    }

    static func runtimeStatePath(t3Home: String? = nil) -> String {
        let home = t3Home ?? defaultT3Home()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("userdata/server-runtime.json")
            .path
    }

    static func runtimeStateExists(t3Home: String? = nil) -> Bool {
        FileManager.default.fileExists(atPath: runtimeStatePath(t3Home: t3Home))
    }

    static func parseRuntimeState(from data: Data) -> T3ServerRuntimeState? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? JSON else {
            return nil
        }
        let port = object["port"] as? Int
        let rawOrigin = object["origin"] as? String
        let origin: String
        if let rawOrigin, rawOrigin.lowercased().hasPrefix("http") {
            origin = rawOrigin.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else if let port, port > 0 {
            origin = "http://127.0.0.1:\(port)"
        } else {
            return nil
        }

        return T3ServerRuntimeState(
            version: object["version"] as? Int,
            pid: object["pid"] as? Int,
            port: port,
            origin: origin,
            serverVersion: object["serverVersion"] as? String
        )
    }

    static func webSocketURL(origin: String, ticket: String) -> URL? {
        let trimmed = origin.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let wsOrigin: String
        if trimmed.lowercased().hasPrefix("https://") {
            wsOrigin = "wss://" + trimmed.dropFirst("https://".count)
        } else if trimmed.lowercased().hasPrefix("http://") {
            wsOrigin = "ws://" + trimmed.dropFirst("http://".count)
        } else {
            return nil
        }

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=%#")
        guard let encodedTicket = ticket.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "\(wsOrigin)/ws?orchestrationProtocol=\(orchestrationProtocolVersion)&wsTicket=\(encodedTicket)")
    }

    // MARK: - Lifecycle

    func start() {
        queue.async {
            self.stopped = false
            self.connectLocked()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.connecting = false
            self.clearTimersLocked()
            self.closeSocketLocked(reason: "T3 client stopped")
        }
    }

    func reconnect() {
        queue.async {
            self.stopped = false
            self.connecting = false
            self.reconnectAttempt = 0
            self.clearTimersLocked()
            self.closeSocketLocked(reason: "Reconnecting to T3 Code")
            self.connectLocked()
        }
    }

    func refreshConfig() {
        queue.async {
            guard self.isConnectedLocked else { return }
            self.fetchInitialConfigLocked()
        }
    }

    func setModelSelection(
        threadID: String,
        selection: T3ModelSelection,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let command = Self.makeSetModelSelectionCommand(
            commandID: "cmd:\(UUID().uuidString.lowercased())",
            threadID: threadID,
            selection: selection
        )
        t3Log.info("Dispatching thread.model-selection.set thread=\(threadID, privacy: .public) instance=\(selection.instanceId ?? "nil", privacy: .public) model=\(selection.model, privacy: .public) options=\(selection.options?.count ?? 0)")
        callRpc(tag: "orchestration.dispatchCommand", payload: command) { [weak self] result in
            switch result {
            case .success:
                t3Log.info("thread.model-selection.set succeeded thread=\(threadID, privacy: .public) model=\(selection.model, privacy: .public)")
            case let .failure(error):
                t3Log.error("thread.model-selection.set failed thread=\(threadID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            let mapped: Result<Void, Error> = result.map { _ in () }
            self?.deliver { completion(mapped) }
        }
    }

    // MARK: - Session Persistence (0600)

    func loadStoredSession() -> T3StoredSession? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sessionFilePath)),
              let session = try? JSONDecoder().decode(T3StoredSession.self, from: data),
              !session.token.isEmpty,
              !session.sessionId.isEmpty else {
            return nil
        }
        return session
    }

    func saveStoredSession(_ session: T3StoredSession) throws {
        let fileURL = URL(fileURLWithPath: sessionFilePath)
        let directoryURL = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(directoryURL.path, 0o700)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(session)
        data.append(0x0A)

        guard fileManager.createFile(
            atPath: sessionFilePath,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionFilePath)
        _ = chmod(sessionFilePath, 0o600)
    }

    // MARK: - Auth & Connection

    private func readRuntimeState() -> T3ServerRuntimeState? {
        let path = Self.runtimeStatePath(t3Home: t3Home)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return Self.parseRuntimeState(from: data)
    }

    private func issueNewSession() throws -> T3StoredSession {
        guard FileManager.default.isExecutableFile(atPath: t3Bin) else {
            throw T3CodeClientError.cliNotFound(t3Bin)
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: t3Bin)
        process.arguments = [
            "auth",
            "session",
            "issue",
            "--scope", "orchestration:read",
            "--scope", "orchestration:operate",
            "--label", Self.sessionLabel,
            "--ttl", Self.sessionTTL,
            "--json",
        ]
        var env = ProcessInfo.processInfo.environment
        env["T3CODE_HOME"] = t3Home
        process.environment = env
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let doneSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in doneSemaphore.signal() }

        var stdoutData = Data()
        var stderrData = Data()
        let drainGroup = DispatchGroup()

        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        try process.run()

        if doneSemaphore.wait(timeout: .now() + 15) == .timedOut {
            process.terminate()
            throw T3CodeClientError.sessionIssueFailed("t3 auth session issue timed out")
        }
        drainGroup.wait()

        guard process.terminationStatus == 0 else {
            let errText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
            throw T3CodeClientError.sessionIssueFailed(errText.isEmpty ? "exit \(process.terminationStatus)" : errText)
        }

        guard let object = try? JSONSerialization.jsonObject(with: stdoutData) as? JSON,
              let sessionId = object["sessionId"] as? String, !sessionId.isEmpty,
              let token = object["token"] as? String, !token.isEmpty else {
            throw T3CodeClientError.sessionIssueFailed("t3 auth session issue did not return sessionId and token")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let session = T3StoredSession(
            sessionId: sessionId,
            token: token,
            createdAt: formatter.string(from: Date())
        )
        try saveStoredSession(session)
        return session
    }

    private func mintWebSocketTicket(origin: String, forceNewSession: Bool = false) throws -> String {
        var session = forceNewSession ? nil : loadStoredSession()
        if session == nil {
            session = try issueNewSession()
        }
        guard var activeSession = session else {
            throw T3CodeClientError.sessionIssueFailed("Unable to obtain session")
        }

        var response = try requestWebSocketTicket(origin: origin, bearerToken: activeSession.token)
        if (response.statusCode == 401 || response.statusCode == 403), !forceNewSession {
            activeSession = try issueNewSession()
            response = try requestWebSocketTicket(origin: origin, bearerToken: activeSession.token)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw T3CodeClientError.ticketRequestFailed(response.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? JSON,
              let ticket = json["ticket"] as? String,
              !ticket.isEmpty else {
            throw T3CodeClientError.invalidTicketResponse
        }
        return ticket
    }

    private func requestWebSocketTicket(origin: String, bearerToken: String) throws -> (statusCode: Int, data: Data) {
        let trimmed = origin.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/api/auth/websocket-ticket") else {
            throw T3CodeClientError.invalidWebSocketURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let semaphore = DispatchSemaphore(value: 0)
        var capturedData = Data()
        var capturedResponse: URLResponse?
        var capturedError: Error?

        let task = urlSession.dataTask(with: request) { data, response, error in
            if let data { capturedData = data }
            capturedResponse = response
            capturedError = error
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 12)

        if let capturedError {
            throw capturedError
        }
        let statusCode = (capturedResponse as? HTTPURLResponse)?.statusCode ?? 0
        return (statusCode, capturedData)
    }

    private func connectLocked() {
        guard !stopped, !connecting else { return }
        connecting = true
        deliver { [weak self] in self?.onConnectionChange?(.connecting) }

        guard let runtime = readRuntimeState() else {
            connecting = false
            scheduleReconnectLocked(reason: "T3 Code offline")
            return
        }

        currentOrigin = runtime.origin
        let origin = runtime.origin

        authQueue.async { [weak self] in
            guard let self else { return }
            do {
                let ticket = try self.mintWebSocketTicket(origin: origin)
                guard let wsURL = Self.webSocketURL(origin: origin, ticket: ticket) else {
                    throw T3CodeClientError.invalidWebSocketURL
                }
                self.queue.async {
                    guard !self.stopped else {
                        self.connecting = false
                        return
                    }
                    self.openWebSocketLocked(url: wsURL)
                }
            } catch {
                self.queue.async {
                    self.connecting = false
                    self.scheduleReconnectLocked(reason: error.localizedDescription)
                }
            }
        }
    }

    private func openWebSocketLocked(url: URL) {
        closeSocketLocked(reason: "Replacing WebSocket")
        let task = urlSession.webSocketTask(with: url)
        webSocketTask = task
        isSocketOpen = false

        let timeoutItem = DispatchWorkItem { [weak self, weak task] in
            guard let self, let task, self.webSocketTask === task, !self.isSocketOpen else { return }
            self.connecting = false
            self.closeSocketLocked(reason: "WebSocket open timeout")
            self.scheduleReconnectLocked(reason: "WebSocket open timeout")
        }
        connectTimeoutWorkItem = timeoutItem
        queue.asyncAfter(deadline: .now() + 10, execute: timeoutItem)

        task.resume()
        receiveNext(on: task)
    }

    fileprivate func handleWebSocketDidOpen(_ task: URLSessionWebSocketTask) {
        queue.async {
            guard !self.stopped, self.webSocketTask === task else {
                task.cancel(with: .normalClosure, reason: nil)
                return
            }
            self.connectTimeoutWorkItem?.cancel()
            self.connectTimeoutWorkItem = nil
            self.connecting = false
            self.isSocketOpen = true
            self.reconnectAttempt = 0
            self.streamHandlers.removeAll()

            let origin = self.currentOrigin ?? ""
            self.deliver { [weak self] in self?.onConnectionChange?(.connected(origin: origin)) }
            self.startPingTimerLocked()
            self.bootstrapStreamsLocked()
        }
    }

    fileprivate func handleWebSocketDidClose(
        _ task: URLSessionWebSocketTask,
        closeCode: URLSessionWebSocketTask.CloseCode
    ) {
        queue.async {
            guard self.webSocketTask === task else { return }
            self.connecting = false
            self.handleSocketClosedLocked(reason: "Disconnected (\(closeCode.rawValue))")
        }
    }

    fileprivate func handleWebSocketDidFail(_ task: URLSessionWebSocketTask, error: Error) {
        queue.async {
            guard self.webSocketTask === task else { return }
            self.connecting = false
            self.handleSocketClosedLocked(reason: error.localizedDescription)
        }
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            self.queue.async {
                guard self.webSocketTask === task else { return }
                switch result {
                case let .success(message):
                    switch message {
                    case let .string(text):
                        self.handleIncomingMessageLocked(text)
                    case let .data(data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleIncomingMessageLocked(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveNext(on: task)
                case let .failure(error):
                    self.connecting = false
                    self.handleSocketClosedLocked(reason: error.localizedDescription)
                }
            }
        }
    }

    private func handleSocketClosedLocked(reason: String) {
        clearTimersLocked()
        closeSocketLocked(reason: reason)
        scheduleReconnectLocked(reason: reason)
    }

    private func closeSocketLocked(reason: String) {
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        isSocketOpen = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        streamHandlers.removeAll()
        rejectAllPendingLocked(reason: reason)
    }

    private func clearTimersLocked() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func startPingTimerLocked() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isConnectedLocked else { return }
            self.sendTextLocked("{\"_tag\":\"Ping\"}")
        }
        pingTimer = timer
        timer.resume()
    }

    private func scheduleReconnectLocked(reason: String) {
        guard !stopped, reconnectWorkItem == nil else { return }
        let index = min(reconnectAttempt, Self.reconnectDelays.count - 1)
        let delay = Self.reconnectDelays[index]
        reconnectAttempt += 1
        deliver { [weak self] in self?.onConnectionChange?(.offline(reason: reason)) }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.connectLocked()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - Orchestration V2 RPC & Streams

    private var isConnectedLocked: Bool {
        sendTextOverride != nil || (webSocketTask != nil && isSocketOpen)
    }

    func bootstrapStreamsForTesting() {
        if deliverCallbacksSynchronously {
            bootstrapStreamsLocked()
        } else {
            queue.sync { bootstrapStreamsLocked() }
        }
    }

    private func bootstrapStreamsLocked() {
        fetchInitialConfigLocked()

        subscribeStreamLocked(
            tag: "subscribeServerConfig",
            payload: [
                "usageLimitSources": true,
                "workspaceSnapshotsOnDemand": true,
            ]
        ) { [weak self] values in
            self?.handleServerConfigStreamValues(values)
        }

        subscribeStreamLocked(
            tag: "orchestration.subscribeShell",
            payload: ["omitIdleSubagents": true]
        ) { [weak self] values in
            self?.handleShellStreamValues(values)
        }
    }

    private func fetchInitialConfigLocked() {
        callRpcLocked(tag: "server.getConfig", payload: [:]) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                guard let raw, let config = Self.decodeConfigPayload(raw) else {
                    t3Log.error("Failed to decode server.getConfig payload")
                    return
                }
                t3Log.info("Loaded server.getConfig: providers=\(config.providers?.count ?? 0) favorites=\(config.settings?.favorites?.count ?? 0)")
                self.deliver { [weak self] in self?.onConfigSnapshot?(config) }
            case let .failure(error):
                t3Log.error("server.getConfig RPC failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func handleServerConfigStreamValues(_ values: [Any]) {
        for raw in values {
            guard let event = raw as? JSON,
                  let type = event["type"] as? String,
                  let payload = event["payload"] as? JSON else { continue }

            switch type {
            case "snapshot":
                if let configRaw = payload["config"],
                   let config = Self.decodeConfigPayload(configRaw) {
                    deliver { [weak self] in self?.onConfigSnapshot?(config) }
                }
            case "providerStatuses":
                if let providersRaw = payload["providers"] {
                    let providers: [T3ServerProvider] = Self.decodeJSONArray(providersRaw)
                    if !providers.isEmpty {
                        deliver { [weak self] in self?.onProvidersUpdated?(providers) }
                    }
                }
            case "settingsUpdated":
                if let settingsRaw = payload["settings"],
                   let settings: T3ServerSettingsPayload = Self.decodeJSONValue(settingsRaw) {
                    deliver { [weak self] in self?.onSettingsUpdated?(settings) }
                }
            default:
                break
            }
        }
    }

    private func handleShellStreamValues(_ values: [Any]) {
        var events: [T3ShellEvent] = []
        events.reserveCapacity(values.count)

        for raw in values {
            guard let item = raw as? JSON, let kind = item["kind"] as? String else { continue }

            switch kind {
            case "snapshot":
                guard let snapshot = item["snapshot"] as? JSON else { continue }
                let projects: [T3ProjectShell] = snapshot["projects"].map(Self.decodeJSONArray) ?? []
                let threads: [T3ThreadShell] = snapshot["threads"].map(Self.decodeJSONArray) ?? []
                let isEnrichmentOnly: Bool
                if let roots = item["resolvedRepositoryIdentityRoots"], !(roots is NSNull) {
                    isEnrichmentOnly = true
                } else {
                    isEnrichmentOnly = false
                }
                t3Log.info("Shell snapshot: projects=\(projects.count) threads=\(threads.count) enrichmentOnly=\(isEnrichmentOnly)")
                events.append(.snapshot(projects: projects, threads: threads, isEnrichmentOnly: isEnrichmentOnly))

            case "project.updated":
                if let projectRaw = item["project"],
                   let project: T3ProjectShell = Self.decodeJSONValue(projectRaw) {
                    events.append(.projectUpdated(project))
                }

            case "project.removed":
                if let projectID = item["projectId"] as? String {
                    events.append(.projectRemoved(projectID))
                }

            case "thread.updated":
                if let threadRaw = item["thread"],
                   let thread: T3ThreadShell = Self.decodeJSONValue(threadRaw) {
                    let location = item["location"] as? String ?? "active"
                    events.append(.threadUpdated(thread, location: location))
                }

            case "thread.removed":
                if let threadID = item["threadId"] as? String {
                    let location = item["location"] as? String ?? "active"
                    events.append(.threadRemoved(threadID, location: location))
                }

            default:
                break
            }
        }

        guard !events.isEmpty else { return }

        deliver { [weak self] in
            guard let self else { return }
            if let onShellBatch = self.onShellBatch {
                onShellBatch(events)
                return
            }
            for event in events {
                switch event {
                case let .snapshot(projects, threads, isEnrichmentOnly):
                    self.onShellSnapshot?(projects, threads, isEnrichmentOnly)
                case let .projectUpdated(project):
                    self.onProjectUpdated?(project)
                case let .projectRemoved(projectID):
                    self.onProjectRemoved?(projectID)
                case let .threadUpdated(thread, location):
                    self.onThreadUpdated?(thread, location)
                case let .threadRemoved(threadID, location):
                    self.onThreadRemoved?(threadID, location)
                }
            }
        }
    }

    func handleIncomingMessage(_ raw: String) {
        if deliverCallbacksSynchronously {
            handleIncomingMessageLocked(raw)
        } else {
            queue.sync { handleIncomingMessageLocked(raw) }
        }
    }

    private func handleIncomingMessageLocked(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let msg = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
              let tag = msg["_tag"] as? String else {
            return
        }

        if tag == "Pong" { return }

        guard let reqID = Self.stringifyID(msg["requestId"]) else { return }

        if tag == "Chunk" {
            if isConnectedLocked, let ack = try? Self.makeAckFrame(requestID: reqID) {
                sendTextLocked(ack)
            }
            if let handler = streamHandlers[reqID],
               let values = msg["values"] as? [Any],
               !values.isEmpty {
                handler(values)
            }
            return
        }

        if tag == "Exit" {
            streamHandlers.removeValue(forKey: reqID)
            guard let pending = pendingCalls.removeValue(forKey: reqID) else { return }
            pending.timeout.cancel()

            if let exit = msg["exit"] as? JSON,
               exit["_tag"] as? String == "Success" {
                pending.completion(.success(exit["value"]))
            } else {
                let detail = Self.formatExitError(msg["exit"])
                pending.completion(.failure(T3CodeClientError.rpcFailure(detail)))
            }
        }
    }

    func callRpc(tag: String, payload: JSON, completion: @escaping RpcCompletion) {
        if deliverCallbacksSynchronously {
            callRpcLocked(tag: tag, payload: payload, completion: completion)
        } else {
            queue.async { self.callRpcLocked(tag: tag, payload: payload, completion: completion) }
        }
    }

    private func callRpcLocked(tag: String, payload: JSON, completion: @escaping RpcCompletion) {
        guard isConnectedLocked else {
            completion(.failure(T3CodeClientError.notConnected))
            return
        }

        let id = String(nextRequestID)
        nextRequestID += 1

        let frame: String
        do {
            frame = try Self.makeRequestFrame(id: id, tag: tag, payload: payload)
        } catch {
            completion(.failure(error))
            return
        }

        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingCalls.removeValue(forKey: id) else { return }
            pending.completion(.failure(T3CodeClientError.rpcTimeout(tag)))
        }
        pendingCalls[id] = (completion: completion, timeout: timeoutItem)
        queue.asyncAfter(deadline: .now() + Self.rpcTimeout, execute: timeoutItem)
        sendTextLocked(frame)
    }

    @discardableResult
    private func subscribeStreamLocked(tag: String, payload: JSON, onValues: @escaping StreamHandler) -> String {
        guard isConnectedLocked else { return "" }
        let id = String(nextRequestID)
        nextRequestID += 1
        streamHandlers[id] = onValues

        if let frame = try? Self.makeRequestFrame(id: id, tag: tag, payload: payload) {
            sendTextLocked(frame)
        }
        return id
    }

    private func sendTextLocked(_ text: String) {
        if let sendTextOverride {
            sendTextOverride(text)
            return
        }
        webSocketTask?.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async {
                guard self.isSocketOpen else { return }
                self.handleSocketClosedLocked(reason: error.localizedDescription)
            }
        }
    }

    private func rejectAllPendingLocked(reason: String) {
        let calls = pendingCalls.values
        pendingCalls.removeAll()
        for call in calls {
            call.timeout.cancel()
            call.completion(.failure(T3CodeClientError.rpcFailure(reason)))
        }
    }

    private func deliver(_ block: @escaping () -> Void) {
        if deliverCallbacksSynchronously {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    // MARK: - Frame Builders & Helpers

    static func makeRequestFrame(id: String, tag: String, payload: JSON) throws -> String {
        let object: JSON = [
            "_tag": "Request",
            "id": id,
            "tag": tag,
            "payload": payload,
            "headers": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    static func makeAckFrame(requestID: String) throws -> String {
        let object: JSON = [
            "_tag": "Ack",
            "requestId": requestID,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    static func makeSetModelSelectionCommand(
        commandID: String,
        threadID: String,
        selection: T3ModelSelection
    ) -> JSON {
        [
            "type": "thread.model-selection.set",
            "commandId": commandID,
            "threadId": threadID,
            "modelSelection": selection.toJSONDictionary(),
        ]
    }

    private static func stringifyID(_ raw: Any?) -> String? {
        if let string = raw as? String { return string }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    private static func formatExitError(_ exit: Any?) -> String {
        guard let dict = exit as? JSON else { return "Unknown RPC failure" }
        let target = dict["cause"] ?? dict
        if JSONSerialization.isValidJSONObject(target),
           let data = try? JSONSerialization.data(withJSONObject: target),
           let text = String(data: data, encoding: .utf8) {
            return String(text.prefix(300))
        }
        return String(describing: target).prefix(300).description
    }

    private static func decodeJSONValue<T: Decodable>(_ raw: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func decodeJSONArray<T: Decodable>(_ raw: Any) -> [T] {
        guard let list = raw as? [Any] else { return [] }
        if let whole: [T] = decodeJSONValue(list) {
            return whole
        }
        let decoder = JSONDecoder()
        var decoded: [T] = []
        decoded.reserveCapacity(list.count)
        for item in list {
            guard JSONSerialization.isValidJSONObject(item),
                  let data = try? JSONSerialization.data(withJSONObject: item),
                  let value = try? decoder.decode(T.self, from: data) else {
                continue
            }
            decoded.append(value)
        }
        return decoded
    }

    private static func decodeConfigPayload(_ raw: Any) -> T3ServerConfigPayload? {
        if let whole: T3ServerConfigPayload = decodeJSONValue(raw) {
            return whole
        }
        guard let dict = raw as? JSON else { return nil }
        let env: T3EnvironmentInfo? = dict["environment"].flatMap(decodeJSONValue)
        let providers: [T3ServerProvider]? = dict["providers"].map(decodeJSONArray)
        let settings: T3ServerSettingsPayload? = dict["settings"].flatMap(decodeJSONValue)
        if env == nil && providers == nil && settings == nil {
            return nil
        }
        return T3ServerConfigPayload(environment: env, providers: providers, settings: settings)
    }
}
