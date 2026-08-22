import Foundation
import Network
import AgentTransmissionCore

enum CodexDesktopIPCError: LocalizedError {
    case notConnected
    case invalidResponse
    case rejected(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: "Experimental Codex Desktop bridge is not connected"
        case .invalidResponse: "Codex Desktop returned an incompatible bridge response"
        case let .rejected(message): "Codex Desktop rejected the shift: \(message)"
        case .timeout: "Codex Desktop did not acknowledge the shift; this version may be incompatible"
        }
    }
}

final class CodexDesktopIPCClient {
    typealias JSON = [String: Any]
    typealias Completion = (Result<JSON, Error>) -> Void

    var onConnected: (() -> Void)?
    var onDisconnected: ((String) -> Void)?
    var onFocusedThreadChanged: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "CodexTransmission.DesktopIPC")
    private var connection: NWConnection?
    private var buffer = Data()
    private var clientID: String?
    private var focusedThreadID: String?
    private var pending: [String: Completion] = [:]
    private var reconnectBackoff = ReconnectBackoff()
    private var reconnectWorkItem: DispatchWorkItem?
    private var shouldReconnect = false

    private var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/ipc/ipc.sock").path
    }

    func reconnect() {
        queue.async {
            self.shouldReconnect = true
            self.reconnectBackoff.reset()
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.connectLocked()
        }
    }

    private func connectLocked() {
        closeConnectionLocked()

        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, self.connection === connection else { return }
            switch state {
            case .ready:
                self.receiveNext(from: connection)
                self.sendRequestLocked(method: "initialize", params: [
                    "clientType": "codex-transmission",
                ], version: 0, requiresInitialization: false) { [weak self, weak connection] result in
                    guard let self, self.connection === connection else { return }
                    switch result {
                    case let .success(response):
                        guard let responseResult = response["result"] as? JSON,
                              let clientID = responseResult["clientId"] as? String else {
                            self.connectionFailed(CodexDesktopIPCError.invalidResponse)
                            return
                        }
                        self.clientID = clientID
                        self.reconnectBackoff.reset()
                        DispatchQueue.main.async { [weak self] in self?.onConnected?() }
                    case let .failure(error):
                        self.connectionFailed(error)
                    }
                }
            case let .failed(error):
                self.connectionFailed(error)
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func updateSettings(
        threadID: String,
        preset: ModelPreset? = nil,
        fastMode: Bool? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            var threadSettings: JSON = [:]
            if let preset {
                threadSettings["model"] = preset.model
                threadSettings["effort"] = preset.effort.rawValue
            }
            if let fastMode {
                threadSettings["serviceTier"] = fastMode ? "priority" : NSNull()
            }
            self.sendRequestLocked(
                method: "thread-follower-update-thread-settings",
                params: [
                    "conversationId": threadID,
                    "threadSettings": threadSettings,
                ],
                version: 1
            ) { result in
                DispatchQueue.main.async { completion(result.map { _ in () }) }
            }
        }
    }

    func close() {
        queue.async {
            self.shouldReconnect = false
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.closeConnectionLocked()
        }
    }

    private func sendRequestLocked(
        method: String,
        params: JSON,
        version: Int,
        requiresInitialization: Bool = true,
        completion: @escaping Completion
    ) {
        guard let connection,
              !requiresInitialization || clientID != nil else {
            completion(.failure(CodexDesktopIPCError.notConnected))
            return
        }

        let requestID = UUID().uuidString
        var message: JSON = [
            "type": "request",
            "requestId": requestID,
            "sourceClientId": clientID ?? "initializing-client",
            "version": version,
            "method": method,
            "params": params,
            "timeoutMs": 10_000,
        ]
        if method == "initialize" { message.removeValue(forKey: "timeoutMs") }

        do {
            let payload = try JSONSerialization.data(withJSONObject: message)
            var length = UInt32(payload.count).littleEndian
            var frame = withUnsafeBytes(of: &length) { Data($0) }
            frame.append(payload)
            pending[requestID] = completion
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                self.queue.async {
                    self.pending.removeValue(forKey: requestID)?(.failure(error))
                }
            })
            queue.asyncAfter(deadline: .now() + 11) { [weak self] in
                self?.pending.removeValue(forKey: requestID)?(.failure(CodexDesktopIPCError.timeout))
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func receiveNext(from connection: NWConnection?) {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, self.connection === connection else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.consumeFrames()
            }
            if let error {
                self.connectionFailed(error)
            } else if isComplete {
                self.connectionFailed(CodexDesktopIPCError.notConnected)
            } else {
                self.receiveNext(from: connection)
            }
        }
    }

    private func consumeFrames() {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { raw in
                raw.loadUnaligned(as: UInt32.self).littleEndian
            }
            guard length > 0, length <= 256 * 1_024 * 1_024 else {
                connectionFailed(CodexDesktopIPCError.invalidResponse)
                return
            }
            let frameLength = 4 + Int(length)
            guard buffer.count >= frameLength else { return }
            let payload = buffer.subdata(in: 4..<frameLength)
            buffer.removeSubrange(0..<frameLength)
            guard let object = try? JSONSerialization.jsonObject(with: payload),
                  let message = object as? JSON else { continue }

            if message["type"] as? String == "broadcast" {
                consumeBroadcast(message)
                continue
            }

            guard message["type"] as? String == "response",
                  let requestID = message["requestId"] as? String,
                  let completion = pending.removeValue(forKey: requestID) else { continue }

            if message["resultType"] as? String == "error" {
                completion(.failure(CodexDesktopIPCError.rejected(message["error"] as? String ?? "unknown error")))
            } else {
                completion(.success(message))
            }
        }
    }

    private func consumeBroadcast(_ message: JSON) {
        guard message["method"] as? String == "thread-stream-following-changed",
              let params = message["params"] as? JSON,
              params["hostId"] as? String == "local",
              let threadID = params["conversationId"] as? String,
              let following = params["following"] as? Bool else { return }

        if following {
            focusedThreadID = threadID
        } else if focusedThreadID == threadID {
            focusedThreadID = nil
        } else {
            return
        }
        let focusedThreadID = focusedThreadID
        DispatchQueue.main.async { [weak self] in
            self?.onFocusedThreadChanged?(focusedThreadID)
        }
    }

    private func connectionFailed(_ error: Error) {
        let detail = error.localizedDescription
        closeConnectionLocked()
        DispatchQueue.main.async { [weak self] in self?.onDisconnected?(detail) }
        scheduleReconnectLocked()
    }

    private func scheduleReconnectLocked() {
        guard shouldReconnect, reconnectWorkItem == nil else { return }
        let delay = reconnectBackoff.nextDelay()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard self.shouldReconnect else { return }
            self.connectLocked()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func closeConnectionLocked() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        clientID = nil
        focusedThreadID = nil
        buffer.removeAll(keepingCapacity: true)
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { $0(.failure(CodexDesktopIPCError.notConnected)) }
    }
}

struct ReconnectBackoff {
    private static let maximumDelay: TimeInterval = 30
    private var delay: TimeInterval = 1

    mutating func nextDelay() -> TimeInterval {
        defer { delay = min(delay * 2, Self.maximumDelay) }
        return delay
    }

    mutating func reset() {
        delay = 1
    }
}
