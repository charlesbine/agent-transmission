import ServiceManagement

final class LaunchAtLoginController {
    enum State {
        case disabled
        case enabled
        case requiresApproval
    }

    var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound, .notRegistered:
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    func toggle() throws {
        switch state {
        case .enabled:
            try SMAppService.mainApp.unregister()
        case .disabled:
            try SMAppService.mainApp.register()
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
