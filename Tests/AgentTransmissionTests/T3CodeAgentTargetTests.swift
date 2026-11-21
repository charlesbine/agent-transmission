import XCTest
@testable import CodexTransmission
@testable import AgentTransmissionCore

final class T3CodeAgentTargetTests: XCTestCase {

    // MARK: - Discovery, URL, Session Permissions & RPC Framing

    func testServerRuntimeParsingAndWebSocketURL() {
        let validJSON = """
        {"version":1,"pid":4242,"port":3773,"origin":"http://127.0.0.1:3773/","serverVersion":"1.2.3"}
        """.data(using: .utf8)!
        let runtime = T3CodeClient.parseRuntimeState(from: validJSON)
        XCTAssertEqual(runtime?.origin, "http://127.0.0.1:3773")
        XCTAssertEqual(runtime?.port, 3773)
        XCTAssertEqual(runtime?.pid, 4242)

        let portOnlyJSON = """
        {"port":4555}
        """.data(using: .utf8)!
        XCTAssertEqual(T3CodeClient.parseRuntimeState(from: portOnlyJSON)?.origin, "http://127.0.0.1:4555")

        let invalidJSON = """
        {"origin":"ftp://invalid"}
        """.data(using: .utf8)!
        XCTAssertNil(T3CodeClient.parseRuntimeState(from: invalidJSON))

        let wsURL = T3CodeClient.webSocketURL(origin: "http://127.0.0.1:3773/", ticket: "tok+a/b=c")
        XCTAssertEqual(
            wsURL?.absoluteString,
            "ws://127.0.0.1:3773/ws?orchestrationProtocol=2&wsTicket=tok%2Ba/b%3Dc"
        )

        let wssURL = T3CodeClient.webSocketURL(origin: "https://t3.example.test", ticket: "abc123")
        XCTAssertEqual(
            wssURL?.absoluteString,
            "wss://t3.example.test/ws?orchestrationProtocol=2&wsTicket=abc123"
        )
    }

    func testSessionPersistenceEnforces0600Permissions() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-transmission-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionPath = tempDir.appendingPathComponent("nested/session.json").path
        let client = T3CodeClient(t3Home: tempDir.path, sessionFilePath: sessionPath)

        let saved = T3StoredSession(
            sessionId: "sess-123",
            token: "test-ephemeral-token",
            createdAt: "2026-11-21T12:00:00.000Z"
        )
        try client.saveStoredSession(saved)

        let loaded = client.loadStoredSession()
        XCTAssertEqual(loaded, saved)

        let attributes = try FileManager.default.attributesOfItem(atPath: sessionPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    func testOrchestrationV2RpcFramingAcksAndStreams() throws {
        let client = T3CodeClient()
        client.deliverCallbacksSynchronously = true

        var sentFrames: [[String: Any]] = []
        client.sendTextOverride = { raw in
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                sentFrames.append(obj)
            }
        }

        var receivedConfig: T3ServerConfigPayload?
        var receivedProviders: [T3ServerProvider]?
        var receivedSettings: T3ServerSettingsPayload?
        var receivedSnapshot: (projects: [T3ProjectShell], threads: [T3ThreadShell], enrichment: Bool)?
        var receivedThreadUpdate: (thread: T3ThreadShell, location: String)?
        var receivedThreadRemoved: (id: String, location: String)?

        client.onConfigSnapshot = { receivedConfig = $0 }
        client.onProvidersUpdated = { receivedProviders = $0 }
        client.onSettingsUpdated = { receivedSettings = $0 }
        client.onShellSnapshot = { receivedSnapshot = ($0, $1, $2) }
        client.onThreadUpdated = { receivedThreadUpdate = ($0, $1) }
        client.onThreadRemoved = { receivedThreadRemoved = ($0, $1) }

        client.bootstrapStreamsForTesting()

        // 3 bootstrap requests: server.getConfig (id=1), subscribeServerConfig (id=2), orchestration.subscribeShell (id=3)
        XCTAssertEqual(sentFrames.count, 3)
        XCTAssertEqual(sentFrames[0]["_tag"] as? String, "Request")
        XCTAssertEqual(sentFrames[0]["id"] as? String, "1")
        XCTAssertEqual(sentFrames[0]["tag"] as? String, "server.getConfig")

        XCTAssertEqual(sentFrames[1]["id"] as? String, "2")
        XCTAssertEqual(sentFrames[1]["tag"] as? String, "subscribeServerConfig")

        XCTAssertEqual(sentFrames[2]["id"] as? String, "3")
        XCTAssertEqual(sentFrames[2]["tag"] as? String, "orchestration.subscribeShell")

        // Pong should be ignored cleanly
        client.handleIncomingMessage(#"{"_tag":"Pong"}"#)
        XCTAssertEqual(sentFrames.count, 3)

        // Exit for server.getConfig (id=1)
        client.handleIncomingMessage(#"""
        {
          "_tag": "Exit",
          "requestId": "1",
          "exit": {
            "_tag": "Success",
            "value": {
              "environment": { "environmentId": "env-terra", "label": "Terra" },
              "providers": [],
              "settings": { "favorites": [{ "provider": "claudeAgent", "model": "claude-opus-5-5" }] }
            }
          }
        }
        """#)
        XCTAssertEqual(receivedConfig?.environment?.environmentId, "env-terra")
        XCTAssertEqual(receivedConfig?.settings?.favorites?.count, 1)

        // Chunk on subscribeServerConfig (id=2) -> must send Ack and dispatch providerStatuses + settingsUpdated
        client.handleIncomingMessage(#"""
        {
          "_tag": "Chunk",
          "requestId": "2",
          "values": [
            {
              "type": "providerStatuses",
              "payload": {
                "providers": [{
                  "instanceId": "claudeAgent",
                  "driver": "claudeAgent",
                  "displayName": "Claude",
                  "enabled": true,
                  "status": "ready",
                  "models": [{ "slug": "claude-opus-5-5", "name": "Claude Opus 5.5" }]
                }]
              }
            },
            {
              "type": "settingsUpdated",
              "payload": {
                "settings": {
                  "favorites": [{ "provider": "claudeAgent", "model": "claude-opus-5-5" }]
                }
              }
            }
          ]
        }
        """#)
        XCTAssertEqual(sentFrames.last?["_tag"] as? String, "Ack")
        XCTAssertEqual(sentFrames.last?["requestId"] as? String, "2")
        XCTAssertEqual(receivedProviders?.first?.instanceId, "claudeAgent")
        XCTAssertEqual(receivedSettings?.favorites?.first?.model, "claude-opus-5-5")

        // Chunk on orchestration.subscribeShell (id=3) -> snapshot, thread.updated, thread.removed
        client.handleIncomingMessage(#"""
        {
          "_tag": "Chunk",
          "requestId": "3",
          "values": [
            {
              "kind": "snapshot",
              "snapshot": {
                "projects": [{ "id": "p-1", "title": "agent-transmission", "workspaceRoot": "/tmp/at" }],
                "threads": [{
                  "id": "th-1",
                  "projectId": "p-1",
                  "title": "Native T3 Target",
                  "providerInstanceId": "claudeAgent",
                  "modelSelection": {
                    "instanceId": "claudeAgent",
                    "model": "claude-opus-5-5",
                    "options": { "effort": "high", "fastMode": true }
                  },
                  "updatedAt": "2026-11-21T10:00:00.000Z",
                  "lastVisitedAt": "2026-11-21T10:05:00Z"
                }]
              }
            }
          ]
        }
        """#)
        XCTAssertEqual(sentFrames.last?["_tag"] as? String, "Ack")
        XCTAssertEqual(sentFrames.last?["requestId"] as? String, "3")
        XCTAssertEqual(receivedSnapshot?.enrichment, false)
        XCTAssertEqual(receivedSnapshot?.projects.first?.title, "agent-transmission")
        XCTAssertEqual(receivedSnapshot?.threads.first?.id, "th-1")
        // Dictionary options should normalize cleanly
        XCTAssertEqual(
            receivedSnapshot?.threads.first?.modelSelection.options,
            [
                T3ProviderOptionSelection(id: "effort", value: .string("high")),
                T3ProviderOptionSelection(id: "fastMode", value: .bool(true)),
            ]
        )

        // Enrichment-only snapshot
        client.handleIncomingMessage(#"""
        {
          "_tag": "Chunk",
          "requestId": "3",
          "values": [
            {
              "kind": "snapshot",
              "resolvedRepositoryIdentityRoots": ["/tmp/at"],
              "snapshot": {
                "projects": [{ "id": "p-1", "title": "agent-transmission-v2" }],
                "threads": []
              }
            },
            {
              "kind": "thread.updated",
              "location": "active",
              "thread": {
                "id": "th-2",
                "projectId": "p-1",
                "title": "Second Thread",
                "providerInstanceId": "codex",
                "modelSelection": { "instanceId": "codex", "model": "gpt-6.2-sol" },
                "updatedAt": "2026-11-21T11:00:00.000Z"
              }
            },
            {
              "kind": "thread.removed",
              "location": "active",
              "threadId": "th-1"
            }
          ]
        }
        """#)
        XCTAssertEqual(receivedSnapshot?.enrichment, true)
        XCTAssertEqual(receivedThreadUpdate?.thread.id, "th-2")
        XCTAssertEqual(receivedThreadRemoved?.id, "th-1")

        // setModelSelection RPC command payload + Failure handling
        var rpcResult: Result<Void, Error>?
        client.setModelSelection(
            threadID: "th-2",
            selection: T3ModelSelection(
                instanceId: "codex",
                model: "gpt-6.2-sol",
                options: [
                    T3ProviderOptionSelection(id: "reasoningEffort", value: .string("xhigh")),
                    T3ProviderOptionSelection(id: "serviceTier", value: .string("priority")),
                ]
            )
        ) { rpcResult = $0 }

        let dispatchFrame = try XCTUnwrap(sentFrames.last)
        XCTAssertEqual(dispatchFrame["_tag"] as? String, "Request")
        XCTAssertEqual(dispatchFrame["tag"] as? String, "orchestration.dispatchCommand")
        let reqID = try XCTUnwrap(dispatchFrame["id"] as? String)
        let payload = try XCTUnwrap(dispatchFrame["payload"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "thread.model-selection.set")
        XCTAssertTrue((payload["commandId"] as? String)?.hasPrefix("cmd:") == true)
        XCTAssertEqual(payload["threadId"] as? String, "th-2")
        let selectionDict = try XCTUnwrap(payload["modelSelection"] as? [String: Any])
        XCTAssertEqual(selectionDict["instanceId"] as? String, "codex")
        XCTAssertEqual(selectionDict["model"] as? String, "gpt-6.2-sol")

        client.handleIncomingMessage("""
        {"_tag":"Exit","requestId":"\(reqID)","exit":{"_tag":"Failure","cause":{"message":"boom"}}}
        """)
        if case let .failure(error) = rpcResult {
            XCTAssertTrue(error.localizedDescription.contains("boom"))
        } else {
            XCTFail("Expected RPC failure")
        }
    }

    // MARK: - Thread Focus Selection (lastVisitedAt / opens.openedAt)

    func testThreadFocusFollowsMostRecentVisitAndOpensTimestamp() {
        let client = FakeT3CodeClient()
        let target = T3CodeAgentTarget(client: client)

        var emittedTasks: [AgentTask] = []
        var focusedHistory: [String?] = []
        target.onTasksChanged = { emittedTasks = $0 }
        target.onFocusedTaskChanged = { focusedHistory.append($0) }

        target.start()

        let project = T3ProjectShell(id: "p-1", title: "lab", workspaceRoot: "/tmp/lab", pinnedAt: nil, archivedAt: nil, deletedAt: nil)
        let alpha = makeThread(id: "t-a", title: "Alpha", updatedAt: "2026-11-21T01:00:00Z", lastVisitedAt: "2026-11-21T01:00:00Z")
        let beta = makeThread(id: "t-b", title: "Beta", updatedAt: "2026-11-21T01:30:00Z", lastVisitedAt: "2026-11-21T02:00:00.000Z")
        let subagent = makeThread(
            id: "t-sub",
            title: "Subagent",
            updatedAt: "2026-11-21T05:00:00Z",
            lastVisitedAt: "2026-11-21T05:00:00Z",
            parentThreadId: "t-b"
        )
        let archived = makeThread(id: "t-arch", title: "Archived", updatedAt: "2026-11-21T06:00:00Z", archivedAt: "2026-11-21T06:00:00Z")

        client.onShellSnapshot?([project], [alpha, beta, subagent, archived], false)

        // Subagent and archived threads are excluded; Beta wins focus via lastVisitedAt
        XCTAssertEqual(emittedTasks.map(\.id), ["t-b", "t-a"])
        XCTAssertEqual(emittedTasks.first?.workspace, "lab")
        XCTAssertEqual(focusedHistory.last ?? nil, "t-b")

        // Enrichment-only snapshot updates project title without wiping threads or focus
        let renamedProject = T3ProjectShell(id: "p-1", title: "lab-terra", workspaceRoot: "/tmp/lab", pinnedAt: nil, archivedAt: nil, deletedAt: nil)
        client.onShellSnapshot?([renamedProject], [], true)
        XCTAssertEqual(emittedTasks.map(\.id), ["t-b", "t-a"])
        XCTAssertEqual(emittedTasks.first?.workspace, "lab-terra")
        XCTAssertEqual(target.focusedThreadID, "t-b")

        // User opens Alpha in T3 Code -> opens.openedAt advances -> focus switches to Alpha
        let openedAlpha = makeThread(
            id: "t-a",
            title: "Alpha",
            updatedAt: "2026-11-21T03:00:00Z",
            lastVisitedAt: "2026-11-21T03:00:00Z",
            openedAt: 1_795_230_000_000
        )
        client.onThreadUpdated?(openedAlpha, "active")
        XCTAssertEqual(target.focusedThreadID, "t-a")
        XCTAssertEqual(focusedHistory.last ?? nil, "t-a")

        // Subagent update with newer openedAt must NOT steal focus
        let openedSub = makeThread(
            id: "t-sub",
            title: "Subagent",
            updatedAt: "2026-11-21T04:00:00Z",
            lastVisitedAt: "2026-11-21T04:00:00Z",
            openedAt: 1_795_239_000_000,
            parentThreadId: "t-a"
        )
        client.onThreadUpdated?(openedSub, "active")
        XCTAssertEqual(target.focusedThreadID, "t-a")

        // Archiving Alpha falls back to Beta
        client.onThreadUpdated?(openedAlpha, "archive")
        XCTAssertEqual(target.focusedThreadID, "t-b")
        XCTAssertEqual(emittedTasks.map(\.id), ["t-b"])
    }

    // MARK: - Dynamic Catalog, Favorites & Default Transmission Map

    func testDynamicCatalogFavoritesAndDefaultTransmissionMap() {
        let client = FakeT3CodeClient()
        let target = T3CodeAgentTarget(client: client)

        // Fallback presets & map before config arrives must be valid and compatible
        XCTAssertTrue(target.defaultTransmissionMap.isCompatible(with: target.supportedPresets))
        XCTAssertEqual(target.name, "T3 Code")
        XCTAssertFalse(target.controlIsExperimental)

        client.onConfigSnapshot?(sampleConfigPayload())

        // Ready models only (disabled Cursor skipped, legacy & hidden models skipped)
        // Favorites come first in exact favorite order: Opus 5.5, GPT-6.2 Sol, Gemini 4 Neon
        XCTAssertEqual(
            target.orderedModels.map(\.slug),
            ["claude-opus-5-5", "gpt-6.2-sol", "gemini-4-neon", "claude-sonnet-5-5"]
        )
        XCTAssertTrue(target.defaultTransmissionMap.isCompatible(with: target.supportedPresets))

        // With 3 favorites, gears 1-6 get 2 slots each across the 3 favorites
        let forward = target.defaultTransmissionMap.forward
        XCTAssertEqual(forward.count, 6)
        XCTAssertEqual(forward[0].model, "claude-opus-5-5")
        XCTAssertEqual(forward[1].model, "claude-opus-5-5")
        XCTAssertEqual(forward[2].model, "gpt-6.2-sol")
        XCTAssertEqual(forward[3].model, "gpt-6.2-sol")
        XCTAssertEqual(forward[4].model, "gemini-4-neon")
        XCTAssertEqual(forward[5].model, "gemini-4-neon")
        XCTAssertEqual(target.defaultTransmissionMap.reverse.model, "claude-opus-5-5")
        XCTAssertEqual(target.defaultTransmissionMap.reverse.effort, .max)
    }

    func testDuplicateModelShortNamesAcrossProvidersAreDisambiguated() {
        let client = FakeT3CodeClient()
        let target = T3CodeAgentTarget(client: client)

        let providers = [
            T3ServerProvider(
                instanceId: "antigravity",
                driver: "antigravity",
                displayName: "Antigravity",
                accentColor: nil,
                badgeLabel: nil,
                enabled: true,
                installed: true,
                status: "ready",
                models: [
                    T3ServerProviderModel(
                        slug: "gemini-4-neon",
                        name: "Gemini 4 Neon",
                        shortName: "Gemini 4 Neon",
                        subProvider: nil,
                        isCustom: nil,
                        isDefault: true,
                        isLegacy: nil,
                        capabilities: nil
                    ),
                ]
            ),
            T3ServerProvider(
                instanceId: "acpRegistry_antigravity_acp",
                driver: "acpRegistry",
                displayName: "Antigravity ACP",
                accentColor: nil,
                badgeLabel: nil,
                enabled: true,
                installed: true,
                status: "ready",
                models: [
                    T3ServerProviderModel(
                        slug: "gemini-4-neon",
                        name: "Gemini 4 Neon",
                        shortName: "Gemini 4 Neon",
                        subProvider: nil,
                        isCustom: nil,
                        isDefault: false,
                        isLegacy: nil,
                        capabilities: nil
                    ),
                ]
            ),
        ]

        client.onConfigSnapshot?(T3ServerConfigPayload(environment: nil, providers: providers, settings: nil))
        XCTAssertEqual(
            target.orderedModels.map(\.displayName),
            ["Gemini 4 Neon (Antigravity)", "Gemini 4 Neon (Antigravity ACP)"]
        )
        XCTAssertTrue(target.defaultTransmissionMap.isCompatible(with: target.supportedPresets))
    }

    // MARK: - Stepping & Apply Payloads

    func testStepEffortAndStepModelFamilyAcrossProviders() {
        let client = FakeT3CodeClient()
        let target = T3CodeAgentTarget(client: client)
        client.onConfigSnapshot?(sampleConfigPayload())

        // Effort stepping within Claude Opus 5.5 (low, medium, high, max, ultra)
        let opusHigh = ModelPreset(name: "Opus 5.5", model: "claude-opus-5-5", effort: .high, provider: "claudeAgent")
        XCTAssertEqual(target.stepEffort(from: opusHigh, direction: 1).effort, .max)
        XCTAssertEqual(target.stepEffort(from: opusHigh, direction: -1).effort, .medium)

        let opusUltra = ModelPreset(name: "Opus 5.5", model: "claude-opus-5-5", effort: .ultra, provider: "claudeAgent")
        XCTAssertEqual(target.stepEffort(from: opusUltra, direction: 1).effort, .ultra)

        // Stepping model family crosses providers: Claude Opus (ultra) -> Codex Sol (ultra) -> Antigravity Gemini (xhigh closest)
        let nextToCodex = target.stepModelFamily(from: opusUltra, direction: 1)
        XCTAssertEqual(nextToCodex.provider, "codex")
        XCTAssertEqual(nextToCodex.model, "gpt-6.2-sol")
        XCTAssertEqual(nextToCodex.effort, .ultra)

        let nextToGemini = target.stepModelFamily(from: nextToCodex, direction: 1)
        XCTAssertEqual(nextToGemini.provider, "antigravity")
        XCTAssertEqual(nextToGemini.model, "gemini-4-neon")
        XCTAssertEqual(nextToGemini.effort, .xhigh)

        // Stepping back returns to Codex Sol at xhigh
        let backToCodex = target.stepModelFamily(from: nextToGemini, direction: -1)
        XCTAssertEqual(backToCodex.provider, "codex")
        XCTAssertEqual(backToCodex.model, "gpt-6.2-sol")
        XCTAssertEqual(backToCodex.effort, .xhigh)
    }

    func testApplyBuildsExactProviderSpecificPayloads() throws {
        let client = FakeT3CodeClient()
        let target = T3CodeAgentTarget(client: client)
        client.onConfigSnapshot?(sampleConfigPayload())

        let project = T3ProjectShell(id: "p-1", title: "lab", workspaceRoot: "/tmp/lab", pinnedAt: nil, archivedAt: nil, deletedAt: nil)
        let claudeThread = makeThread(
            id: "th-claude",
            title: "Claude Thread",
            providerInstanceId: "claudeAgent",
            modelSelection: T3ModelSelection(
                instanceId: "claudeAgent",
                model: "claude-opus-5-5",
                options: [
                    T3ProviderOptionSelection(id: "ultracode", value: .bool(true)),
                    T3ProviderOptionSelection(id: "effort", value: .string("high")),
                ]
            ),
            updatedAt: "2026-11-21T10:00:00Z"
        )
        let codexThread = makeThread(
            id: "th-codex",
            title: "Codex Thread",
            providerInstanceId: "codex",
            modelSelection: T3ModelSelection(
                instanceId: "codex",
                model: "gpt-6.2-sol",
                options: [
                    T3ProviderOptionSelection(id: "reasoningEffort", value: .string("medium")),
                    T3ProviderOptionSelection(id: "serviceTier", value: .string("default")),
                ]
            ),
            updatedAt: "2026-11-21T09:00:00Z"
        )
        let geminiThread = makeThread(
            id: "th-gemini",
            title: "Gemini Thread",
            providerInstanceId: "antigravity",
            modelSelection: T3ModelSelection(
                instanceId: "antigravity",
                model: "gemini-4-neon",
                options: [T3ProviderOptionSelection(id: "thought_level", value: .string("medium"))]
            ),
            updatedAt: "2026-11-21T08:00:00Z"
        )
        client.onShellSnapshot?([project], [claudeThread, codexThread, geminiThread], false)

        // 1. Claude Opus .ultra + fastMode=true -> effort:"ultrathink", fastMode:true, preserves ultracode:true
        let opusUltra = ModelPreset(name: "Opus 5.5", model: "claude-opus-5-5", effort: .ultra, provider: "claudeAgent")
        var result: Result<Void, Error>?
        target.apply(.init(preset: opusUltra, fastMode: true), to: "th-claude") { result = $0 }
        XCTAssertNoThrow(try result?.get())
        XCTAssertEqual(client.lastSetThreadID, "th-claude")
        XCTAssertEqual(client.lastSetSelection?.instanceId, "claudeAgent")
        XCTAssertEqual(client.lastSetSelection?.model, "claude-opus-5-5")
        XCTAssertEqual(
            client.lastSetSelection?.options,
            [
                T3ProviderOptionSelection(id: "ultracode", value: .bool(true)),
                T3ProviderOptionSelection(id: "effort", value: .string("ultrathink")),
                T3ProviderOptionSelection(id: "fastMode", value: .bool(true)),
            ]
        )

        // 2. Codex Sol .xhigh + fastMode=true -> reasoningEffort:"xhigh", serviceTier:"priority"
        let solXHigh = ModelPreset(name: "GPT-6.2 Sol", model: "gpt-6.2-sol", effort: .xhigh, provider: "codex")
        target.apply(.init(preset: solXHigh, fastMode: true), to: "th-codex") { result = $0 }
        XCTAssertNoThrow(try result?.get())
        XCTAssertEqual(client.lastSetSelection?.instanceId, "codex")
        XCTAssertEqual(client.lastSetSelection?.model, "gpt-6.2-sol")
        XCTAssertEqual(
            client.lastSetSelection?.options,
            [
                T3ProviderOptionSelection(id: "reasoningEffort", value: .string("xhigh")),
                T3ProviderOptionSelection(id: "serviceTier", value: .string("priority")),
            ]
        )

        // 3. Codex fast-mode-only toggle -> serviceTier:"default", preserves reasoningEffort:"medium"
        target.apply(.init(fastMode: false), to: "th-codex") { result = $0 }
        XCTAssertNoThrow(try result?.get())
        XCTAssertEqual(
            client.lastSetSelection?.options,
            [
                T3ProviderOptionSelection(id: "reasoningEffort", value: .string("medium")),
                T3ProviderOptionSelection(id: "serviceTier", value: .string("default")),
            ]
        )

        // 4. Antigravity Gemini preset shift with fastMode=true omits unsupported fastMode option cleanly
        let geminiHigh = ModelPreset(name: "Gemini 4 Neon", model: "gemini-4-neon", effort: .high, provider: "antigravity")
        target.apply(.init(preset: geminiHigh, fastMode: true), to: "th-gemini") { result = $0 }
        XCTAssertNoThrow(try result?.get())
        XCTAssertEqual(
            client.lastSetSelection?.options,
            [T3ProviderOptionSelection(id: "thought_level", value: .string("high"))]
        )

        // 5. Antigravity fast-mode-only toggle fails cleanly with descriptive error
        target.apply(.init(fastMode: true), to: "th-gemini") { result = $0 }
        if case let .failure(error) = result {
            XCTAssertEqual(error as? T3CodeClientError, .fastModeUnsupported("Gemini 4 Neon"))
        } else {
            XCTFail("Expected fastModeUnsupported for Gemini")
        }
    }

    // MARK: - Deep Link Generation

    func testT3CodeDeepLinkGeneration() {
        let client = FakeT3CodeClient()
        let target = T3CodeAgentTarget(client: client)

        // Before environmentId arrives, falls back to t3code://new
        XCTAssertEqual(target.taskURL(for: "thread:abc")?.absoluteString, "t3code://new")

        // Once config supplies environmentId, returns t3code://threads/<env>/<thread>
        client.onConfigSnapshot?(T3ServerConfigPayload(
            environment: T3EnvironmentInfo(environmentId: "env/local 1", label: "Local"),
            providers: nil,
            settings: nil
        ))
        XCTAssertEqual(
            target.taskURL(for: "thread:abc/123")?.absoluteString,
            "t3code://threads/env%2Flocal%201/thread:abc%2F123"
        )
    }

    // MARK: - ModelPreset Codable Backwards Compatibility & Target Switcher

    func testModelPresetBackwardsCompatibleDecoding() throws {
        let legacyJSON = #"{"name":"Sol","model":"gpt-5.6-sol","effort":"high"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModelPreset.self, from: legacyJSON)
        XCTAssertEqual(decoded, ModelPreset(name: "Sol", model: "gpt-5.6-sol", effort: .high))
        XCTAssertNil(decoded.provider)

        let providerPreset = ModelPreset(name: "Opus 5.5", model: "claude-opus-5-5", effort: .max, provider: "claudeAgent")
        let encoded = try JSONEncoder().encode(providerPreset)
        let roundTripped = try JSONDecoder().decode(ModelPreset.self, from: encoded)
        XCTAssertEqual(roundTripped, providerPreset)
    }

    func testTargetSwitcherDefaultsPersistenceAndRuntimeSwitching() {
        let suiteName = "T3CodeTargetSwitcherTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Auto-default: T3 Code when server-runtime.json exists, Codex Desktop otherwise
        XCTAssertEqual(
            AgentTargetKind.resolveInitial(defaults: defaults, t3RuntimeExists: true),
            .t3Code
        )
        XCTAssertEqual(
            AgentTargetKind.resolveInitial(defaults: defaults, t3RuntimeExists: false),
            .codexDesktop
        )

        let surface = FakeSwitcherSurface()
        let t3Client = FakeT3CodeClient()
        let t3Target = T3CodeAgentTarget(client: t3Client)
        let codexTarget = FakeCodexLikeTarget()

        let model = AppModel(
            controlSurface: surface,
            initialTargetKind: .t3Code,
            targetFactory: { kind in
                switch kind {
                case .t3Code: t3Target
                case .codexDesktop: codexTarget
                }
            },
            defaults: defaults
        )

        model.start()
        XCTAssertEqual(model.selectedTargetKind, .t3Code)
        XCTAssertEqual(model.agentTargetName, "T3 Code")
        XCTAssertTrue(t3Client.started)

        // When live config arrives, AppModel upgrades map automatically to live T3 Code favorites
        t3Client.onConnectionChange?(.connected(origin: "http://127.0.0.1:3773"))
        t3Client.onConfigSnapshot?(sampleConfigPayload())
        XCTAssertEqual(model.map.preset(for: .first)?.model, "claude-opus-5-5")
        XCTAssertEqual(model.map.preset(for: .third)?.model, "gpt-6.2-sol")

        // Switching to Codex Desktop stops T3, starts Codex, persists choice, and uses Codex map
        model.selectAgentTarget(.codexDesktop)
        XCTAssertTrue(t3Client.stopped)
        XCTAssertTrue(codexTarget.started)
        XCTAssertEqual(model.selectedTargetKind, .codexDesktop)
        XCTAssertEqual(model.agentTargetName, "Codex")
        XCTAssertEqual(
            AgentTargetKind.resolveInitial(defaults: defaults, t3RuntimeExists: true),
            .codexDesktop
        )
        XCTAssertEqual(model.map.preset(for: .first)?.model, "codex-test-model")

        model.stop()
        XCTAssertTrue(codexTarget.stopped)
    }

    // MARK: - Fixtures

    private func makeThread(
        id: String,
        title: String,
        projectId: String = "p-1",
        providerInstanceId: String = "claudeAgent",
        modelSelection: T3ModelSelection = T3ModelSelection(instanceId: "claudeAgent", model: "claude-opus-5-5"),
        updatedAt: String,
        lastVisitedAt: String? = nil,
        openedAt: Double? = nil,
        archivedAt: String? = nil,
        parentThreadId: String? = nil
    ) -> T3ThreadShell {
        T3ThreadShell(
            id: id,
            projectId: projectId,
            title: title,
            providerInstanceId: providerInstanceId,
            modelSelection: modelSelection,
            status: "completed",
            activeRunId: nil,
            latestRunId: nil,
            lineage: parentThreadId.map { T3ThreadLineage(parentThreadId: $0, relationshipToParent: "subagent") },
            createdAt: updatedAt,
            updatedAt: updatedAt,
            archivedAt: archivedAt,
            settledOverride: nil,
            settledAt: nil,
            snoozedUntil: nil,
            pinnedAt: nil,
            lastVisitedAt: lastVisitedAt,
            opens: openedAt.map { T3ThreadOpens(openedAt: $0, score: 1) },
            deletedAt: nil
        )
    }

    private func sampleConfigPayload() -> T3ServerConfigPayload {
        T3ServerConfigPayload(
            environment: T3EnvironmentInfo(environmentId: "env-1", label: "Terra"),
            providers: [
                T3ServerProvider(
                    instanceId: "claudeAgent",
                    driver: "claudeAgent",
                    displayName: "Claude",
                    accentColor: "#E07A5F",
                    badgeLabel: "Claude",
                    enabled: true,
                    installed: true,
                    status: "ready",
                    models: [
                        T3ServerProviderModel(
                            slug: "claude-opus-5-5",
                            name: "Claude Opus 5.5",
                            shortName: "Opus 5.5",
                            subProvider: nil,
                            isCustom: nil,
                            isDefault: true,
                            isLegacy: false,
                            capabilities: T3ModelCapabilities(optionDescriptors: [
                                T3ProviderOptionDescriptor(
                                    id: "effort",
                                    label: "Effort",
                                    description: nil,
                                    type: "select",
                                    options: [
                                        T3ProviderOptionChoice(id: "low", label: "Low", description: nil, isDefault: false),
                                        T3ProviderOptionChoice(id: "medium", label: "Medium", description: nil, isDefault: false),
                                        T3ProviderOptionChoice(id: "high", label: "High", description: nil, isDefault: true),
                                        T3ProviderOptionChoice(id: "max", label: "Max", description: nil, isDefault: false),
                                        T3ProviderOptionChoice(id: "ultrathink", label: "Ultrathink", description: nil, isDefault: false),
                                    ],
                                    currentValue: nil,
                                    role: "reasoning"
                                ),
                                T3ProviderOptionDescriptor(
                                    id: "fastMode",
                                    label: "Fast Mode",
                                    description: nil,
                                    type: "boolean",
                                    options: nil,
                                    currentValue: .bool(false),
                                    role: nil
                                ),
                            ])
                        ),
                        T3ServerProviderModel(
                            slug: "claude-sonnet-5-5",
                            name: "Claude Sonnet 5.5",
                            shortName: "Sonnet 5.5",
                            subProvider: nil,
                            isCustom: nil,
                            isDefault: false,
                            isLegacy: false,
                            capabilities: T3ModelCapabilities(optionDescriptors: [
                                T3ProviderOptionDescriptor(
                                    id: "effort",
                                    label: "Effort",
                                    description: nil,
                                    type: "select",
                                    options: [
                                        T3ProviderOptionChoice(id: "low", label: "Low", description: nil, isDefault: false),
                                        T3ProviderOptionChoice(id: "medium", label: "Medium", description: nil, isDefault: true),
                                        T3ProviderOptionChoice(id: "high", label: "High", description: nil, isDefault: false),
                                    ],
                                    currentValue: nil,
                                    role: "reasoning"
                                ),
                            ])
                        ),
                        T3ServerProviderModel(
                            slug: "claude-old-legacy",
                            name: "Legacy Model",
                            shortName: "Legacy",
                            subProvider: nil,
                            isCustom: nil,
                            isDefault: false,
                            isLegacy: true,
                            capabilities: nil
                        ),
                    ]
                ),
                T3ServerProvider(
                    instanceId: "codex",
                    driver: "codex",
                    displayName: "Codex Personal",
                    accentColor: "#10B981",
                    badgeLabel: "Codex",
                    enabled: true,
                    installed: true,
                    status: "ready",
                    models: [
                        T3ServerProviderModel(
                            slug: "gpt-6.2-sol",
                            name: "GPT-6.2 Sol",
                            shortName: "GPT-6.2 Sol",
                            subProvider: nil,
                            isCustom: nil,
                            isDefault: true,
                            isLegacy: false,
                            capabilities: T3ModelCapabilities(optionDescriptors: [
                                T3ProviderOptionDescriptor(
                                    id: "reasoningEffort",
                                    label: "Reasoning Effort",
                                    description: nil,
                                    type: "select",
                                    options: [
                                        T3ProviderOptionChoice(id: "low", label: "Low", description: nil, isDefault: false),
                                        T3ProviderOptionChoice(id: "medium", label: "Medium", description: nil, isDefault: false),
                                        T3ProviderOptionChoice(id: "high", label: "High", description: nil, isDefault: true),
                                        T3ProviderOptionChoice(id: "xhigh", label: "XHigh", description: nil, isDefault: false),
                                        T3ProviderOptionChoice(id: "max", label: "Max", description: nil, isDefault: false),
                                        T3ProviderOptionChoice(id: "ultra", label: "Ultra", description: nil, isDefault: false),
                                    ],
                                    currentValue: nil,
                                    role: "reasoning"
                                ),
                                T3ProviderOptionDescriptor(
                                    id: "serviceTier",
                                    label: "Service Tier",
                                    description: nil,
                                    type: "select",
                                    options: [
                                        T3ProviderOptionChoice(id: "default", label: "Default", description: nil, isDefault: false),
                                        T3ProviderOptionChoice(id: "priority", label: "Priority", description: nil, isDefault: true),
                                    ],
                                    currentValue: nil,
                                    role: nil
                                ),
                            ])
                        ),
                        T3ServerProviderModel(
                            slug: "gpt-hidden",
                            name: "Hidden GPT",
                            shortName: "Hidden",
                            subProvider: nil,
                            isCustom: nil,
                            isDefault: false,
                            isLegacy: false,
                            capabilities: nil
                        ),
                    ]
                ),
                T3ServerProvider(
                    instanceId: "antigravity",
                    driver: "antigravity",
                    displayName: "Antigravity",
                    accentColor: "#38BDF8",
                    badgeLabel: "Antigravity",
                    enabled: true,
                    installed: true,
                    status: "ready",
                    models: [
                        T3ServerProviderModel(
                            slug: "gemini-4-neon",
                            name: "Gemini 4 Neon",
                            shortName: "Gemini 4 Neon",
                            subProvider: nil,
                            isCustom: nil,
                            isDefault: true,
                            isLegacy: false,
                            capabilities: T3ModelCapabilities(optionDescriptors: [
                                T3ProviderOptionDescriptor(
                                    id: "thought_level",
                                    label: "Thought Level",
                                    description: nil,
                                    type: "select",
                                    options: [
                                        T3ProviderOptionChoice(id: "low", label: "Low", description: nil, isDefault: false),
                                        T3ProviderOptionChoice(id: "medium", label: "Medium", description: nil, isDefault: false),
                                        T3ProviderOptionChoice(id: "high", label: "High", description: nil, isDefault: true),
                                        T3ProviderOptionChoice(id: "xhigh", label: "XHigh", description: nil, isDefault: false),
                                    ],
                                    currentValue: nil,
                                    role: nil
                                ),
                            ])
                        ),
                    ]
                ),
                T3ServerProvider(
                    instanceId: "cursor",
                    driver: "cursor",
                    displayName: "Cursor",
                    accentColor: nil,
                    badgeLabel: nil,
                    enabled: false,
                    installed: false,
                    status: "disabled",
                    models: [
                        T3ServerProviderModel(
                            slug: "cursor-fast",
                            name: "Cursor Fast",
                            shortName: nil,
                            subProvider: nil,
                            isCustom: nil,
                            isDefault: false,
                            isLegacy: false,
                            capabilities: nil
                        ),
                    ]
                ),
            ],
            settings: T3ServerSettingsPayload(
                favorites: [
                    T3ModelFavorite(provider: "claudeAgent", model: "claude-opus-5-5"),
                    T3ModelFavorite(provider: "codex", model: "gpt-6.2-sol"),
                    T3ModelFavorite(provider: "antigravity", model: "gemini-4-neon"),
                ],
                providerModelPreferences: [
                    "codex": T3ProviderModelPreference(modelOrder: nil, hiddenModels: ["gpt-hidden"]),
                ]
            )
        )
    }
}

// MARK: - Test Doubles

private final class FakeT3CodeClient: T3CodeClientProtocol {
    var onConnectionChange: ((T3ConnectionState) -> Void)?
    var onConfigSnapshot: ((T3ServerConfigPayload) -> Void)?
    var onProvidersUpdated: (([T3ServerProvider]) -> Void)?
    var onSettingsUpdated: ((T3ServerSettingsPayload) -> Void)?
    var onShellSnapshot: (([T3ProjectShell], [T3ThreadShell], Bool) -> Void)?
    var onProjectUpdated: ((T3ProjectShell) -> Void)?
    var onProjectRemoved: ((String) -> Void)?
    var onThreadUpdated: ((T3ThreadShell, String) -> Void)?
    var onThreadRemoved: ((String, String) -> Void)?

    var started = false
    var stopped = false
    var reconnected = false
    var lastSetThreadID: String?
    var lastSetSelection: T3ModelSelection?

    func start() { started = true }
    func stop() { stopped = true }
    func reconnect() { reconnected = true }
    func refreshConfig() {}

    func setModelSelection(
        threadID: String,
        selection: T3ModelSelection,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        lastSetThreadID = threadID
        lastSetSelection = selection
        completion(.success(()))
    }
}

private final class FakeSwitcherSurface: ControlSurface {
    let name = "Test controls"
    var onEvents: (([ControlSurfaceEvent]) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?

    func start() { onConnectionChanged?(true) }
    func stop() {}
}

private final class FakeCodexLikeTarget: AgentTarget {
    private static let preset = ModelPreset(name: "Codex", model: "codex-test-model", effort: .high)
    let name = "Codex"
    let controlIsExperimental = true
    let supportedPresets = [FakeCodexLikeTarget.preset]
    let defaultTransmissionMap = TransmissionMap(
        forward: Array(repeating: FakeCodexLikeTarget.preset, count: 6),
        reverse: FakeCodexLikeTarget.preset
    )
    var onStateChanged: ((AgentTargetState) -> Void)?
    var onTasksChanged: (([AgentTask]) -> Void)?
    var onFocusedTaskChanged: ((String?) -> Void)?
    var started = false
    var stopped = false

    func start() {
        started = true
        onStateChanged?(.init(discoveryConnected: true, controlConnected: true))
    }
    func stop() { stopped = true }
    func reconnect() {}
    func refreshTasks() {}
    func stepEffort(from preset: ModelPreset, direction: Int) -> ModelPreset { preset }
    func stepModelFamily(from preset: ModelPreset, direction: Int) -> ModelPreset { preset }
    func apply(_ update: AgentSettingsUpdate, to taskID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
    func taskURL(for taskID: String) -> URL? { nil }
}
