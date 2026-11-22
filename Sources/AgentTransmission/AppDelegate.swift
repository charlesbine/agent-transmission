import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel(
        controlSurface: NiTHOControlSurface(),
        initialTargetKind: AgentTargetKind.resolveInitial(),
        targetFactory: { kind in
            switch kind {
            case .t3Code:
                T3CodeAgentTarget()
            case .codexDesktop:
                CodexAgentTarget()
            }
        }
    )
    private var menuController: StatusMenuController?
    private var hudController: FloatingHUDController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hudController = FloatingHUDController(model: model)
        menuController = StatusMenuController(model: model)
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
