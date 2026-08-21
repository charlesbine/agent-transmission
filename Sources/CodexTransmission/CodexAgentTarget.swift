import Foundation
import AgentTransmissionCore

final class CodexAgentTarget: AgentTarget {
    let name = "Codex"
    let controlIsExperimental = true
    let supportedPresets: [ModelPreset]
    let defaultTransmissionMap: TransmissionMap

    var onStateChanged: ((AgentTargetState) -> Void)?
    var onTasksChanged: (([AgentTask]) -> Void)?
    var onFocusedTaskChanged: ((String?) -> Void)?

    private let catalog = CodexAppServerClient()
    private let control = CodexDesktopIPCClient()
    private var discoveryConnected = false
    private var controlConnected = false

    private static let families: [(name: String, model: String, efforts: [ReasoningEffort])] = [
        ("Luna", "gpt-5.6-luna", [.low, .medium, .high, .xhigh, .max]),
        ("Terra", "gpt-5.6-terra", [.low, .medium, .high, .xhigh, .max, .ultra]),
        ("Sol", "gpt-5.6-sol", [.low, .medium, .high, .xhigh, .max, .ultra]),
    ]

    init() {
        supportedPresets = Self.families.flatMap { name, model, efforts in
            efforts.map { ModelPreset(name: name, model: model, effort: $0) }
        }
        defaultTransmissionMap = TransmissionMap(
            forward: [
                ModelPreset(name: "Luna", model: "gpt-5.6-luna", effort: .max),
                ModelPreset(name: "Sol", model: "gpt-5.6-sol", effort: .medium),
                ModelPreset(name: "Sol", model: "gpt-5.6-sol", effort: .high),
                ModelPreset(name: "Sol", model: "gpt-5.6-sol", effort: .xhigh),
                ModelPreset(name: "Sol", model: "gpt-5.6-sol", effort: .max),
                ModelPreset(name: "Sol", model: "gpt-5.6-sol", effort: .ultra),
            ],
            reverse: ModelPreset(name: "Review", model: "gpt-5.6-sol", effort: .max)
        )
    }

    func start() {
        catalog.onDisconnected = { [weak self] message in
            guard let self else { return }
            self.discoveryConnected = false
            self.publishState(message: message)
        }
        control.onDisconnected = { [weak self] message in
            guard let self else { return }
            self.controlConnected = false
            self.onFocusedTaskChanged?(nil)
            self.publishState(message: message)
        }
        control.onFocusedThreadChanged = { [weak self] taskID in
            self?.onFocusedTaskChanged?(taskID)
        }
        reconnect()
    }

    func stop() {
        catalog.close()
        control.close()
    }

    func reconnect() {
        discoveryConnected = false
        controlConnected = false
        publishState(message: "Connecting to Codex…")

        catalog.connect { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.discoveryConnected = true
                self.publishState()
                self.refreshTasks()
            case let .failure(error):
                self.discoveryConnected = false
                self.publishState(message: error.localizedDescription)
            }
        }
        control.connect { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.controlConnected = true
                self.publishState()
            case let .failure(error):
                self.controlConnected = false
                self.publishState(message: error.localizedDescription)
            }
        }
    }

    func refreshTasks() {
        guard discoveryConnected else { return }
        catalog.listTasks { [weak self] result in
            switch result {
            case let .success(tasks):
                self?.onTasksChanged?(tasks)
            case let .failure(error):
                self?.publishState(message: error.localizedDescription)
            }
        }
    }

    func stepEffort(from preset: ModelPreset, direction: Int) -> ModelPreset {
        guard let family = Self.families.first(where: { $0.model == preset.model }),
              let index = family.efforts.firstIndex(of: preset.effort) else { return preset }
        let next = min(max(index + (direction > 0 ? 1 : -1), 0), family.efforts.count - 1)
        return ModelPreset(name: family.name, model: family.model, effort: family.efforts[next])
    }

    func stepModelFamily(from preset: ModelPreset, direction: Int) -> ModelPreset {
        guard let index = Self.families.firstIndex(where: { $0.model == preset.model }) else { return preset }
        let next = min(max(index + (direction > 0 ? 1 : -1), 0), Self.families.count - 1)
        let family = Self.families[next]
        let effortIndex = ReasoningEffort.allCases.firstIndex(of: preset.effort) ?? 0
        let closestEffort = family.efforts.min {
            abs((ReasoningEffort.allCases.firstIndex(of: $0) ?? 0) - effortIndex)
                < abs((ReasoningEffort.allCases.firstIndex(of: $1) ?? 0) - effortIndex)
        } ?? family.efforts[0]
        return ModelPreset(name: family.name, model: family.model, effort: closestEffort)
    }

    func apply(
        _ update: AgentSettingsUpdate,
        to taskID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        control.updateSettings(
            threadID: taskID,
            preset: update.preset,
            fastMode: update.fastMode,
            completion: completion
        )
    }

    func taskURL(for taskID: String) -> URL? {
        URL(string: "codex://threads/\(taskID)")
    }

    private func publishState(message: String? = nil) {
        onStateChanged?(.init(
            discoveryConnected: discoveryConnected,
            controlConnected: controlConnected,
            message: message
        ))
    }
}
