import Foundation
import AgentTransmissionCore

enum CodexClientError: LocalizedError {
    case executableNotFound
    case notConnected
    case invalidResponse
    case server(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "Codex CLI was not found"
        case .notConnected: "Codex app-server is not connected"
        case .invalidResponse: "Codex returned an invalid response"
        case let .server(message): message
        case let .timeout(method): "Codex timed out handling \(method)"
        }
    }
}

final class CodexAppServerClient {
    typealias JSON = [String: Any]
    typealias Completion = (Result<Any, Error>) -> Void

    var onDisconnected: ((String) -> Void)?

    private let queue = DispatchQueue(label: "AgentTransmission.AppServer")
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var nextID = 1
    private var pending: [Int: Completion] = [:]
    private var lastDiagnostic = ""

    func connect(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if self.process?.isRunning == true {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }

            do {
                let launch = try Self.resolveLaunch()
                let process = Process()
                let stdin = Pipe()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = launch.executable
                process.arguments = launch.arguments + ["app-server", "--stdio"]
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr

                stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if !data.isEmpty { self?.queue.async { self?.consume(data) } }
                }
                stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    self?.queue.async { self?.lastDiagnostic = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                process.terminationHandler = { [weak self] terminated in
                    self?.queue.async { self?.processTerminated(status: terminated.terminationStatus) }
                }

                try process.run()
                self.process = process
                self.input = stdin.fileHandleForWriting
                self.requestLocked(method: "initialize", params: [
                    "clientInfo": [
                        "name": "agent_transmission",
                        "title": "Agent Transmission",
                        "version": "0.1.0",
                    ],
                    "capabilities": ["experimentalApi": false],
                ]) { result in
                    switch result {
                    case .success:
                        self.notifyLocked(method: "initialized", params: [:])
                        DispatchQueue.main.async { completion(.success(())) }
                    case let .failure(error):
                        DispatchQueue.main.async { completion(.failure(error)) }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func listTasks(completion: @escaping (Result<[AgentTask], Error>) -> Void) {
        request(method: "thread/list", params: [
            "archived": false,
            "limit": 24,
            "sortKey": "updated_at",
            "sortDirection": "desc",
            "useStateDbOnly": false,
        ]) { result in
            let parsed: Result<[AgentTask], Error> = result.flatMap { raw in
                guard let response = raw as? JSON,
                      let rows = response["data"] as? [JSON] else {
                    return .failure(CodexClientError.invalidResponse)
                }
                return .success(rows.compactMap(Self.parseTask))
            }
            DispatchQueue.main.async { completion(parsed) }
        }
    }

    func close() {
        queue.async {
            self.process?.terminationHandler = nil
            self.process?.terminate()
            self.process = nil
            self.input = nil
            self.failPending(CodexClientError.notConnected)
        }
    }

    private func request(method: String, params: JSON, completion: @escaping Completion) {
        queue.async { self.requestLocked(method: method, params: params, completion: completion) }
    }

    private func requestLocked(method: String, params: JSON, completion: @escaping Completion) {
        guard process?.isRunning == true, let input else {
            completion(.failure(CodexClientError.notConnected))
            return
        }

        let id = nextID
        nextID += 1
        pending[id] = completion

        do {
            var data = try JSONSerialization.data(withJSONObject: [
                "id": id,
                "method": method,
                "params": params,
            ])
            data.append(0x0A)
            try input.write(contentsOf: data)
        } catch {
            pending.removeValue(forKey: id)?(.failure(error))
            return
        }

        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, let callback = self.pending.removeValue(forKey: id) else { return }
            callback(.failure(CodexClientError.timeout(method)))
        }
    }

    private func notifyLocked(method: String, params: JSON) {
        guard let input else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: [
                "method": method,
                "params": params,
            ])
            data.append(0x0A)
            try input.write(contentsOf: data)
        } catch {
            lastDiagnostic = error.localizedDescription
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? JSON,
                  let id = message["id"] as? Int,
                  let callback = pending.removeValue(forKey: id) else { continue }

            if let error = message["error"] {
                callback(.failure(CodexClientError.server(String(describing: error))))
            } else {
                callback(.success(message["result"] ?? [:]))
            }
        }
    }

    private func processTerminated(status: Int32) {
        process = nil
        input = nil
        let detail = lastDiagnostic.isEmpty ? "Codex app-server exited (\(status))" : lastDiagnostic
        failPending(CodexClientError.server(detail))
        DispatchQueue.main.async { [weak self] in self?.onDisconnected?(detail) }
    }

    private func failPending(_ error: Error) {
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { $0(.failure(error)) }
    }

    private static func parseTask(_ row: JSON) -> AgentTask? {
        guard let id = row["id"] as? String else { return nil }
        let title = (row["name"] as? String)?.nilIfBlank
            ?? (row["title"] as? String)?.nilIfBlank
            ?? (row["preview"] as? String)?.nilIfBlank
            ?? "Untitled task"
        let cwd = row["cwd"] as? String
        let workspace = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex"
        let updatedAt = row["updatedAt"] as? Int ?? 0
        return AgentTask(id: id, title: title, workspace: workspace, updatedAt: updatedAt)
    }

    private static func resolveLaunch() throws -> (executable: URL, arguments: [String]) {
        let fileManager = FileManager.default
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_CLI_PATH"],
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ].compactMap { $0 }

        if let candidate = candidates.first(where: fileManager.isExecutableFile(atPath:)) {
            return (URL(fileURLWithPath: candidate), [])
        }
        if fileManager.isExecutableFile(atPath: "/usr/bin/env") {
            return (URL(fileURLWithPath: "/usr/bin/env"), ["codex"])
        }
        throw CodexClientError.executableNotFound
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
