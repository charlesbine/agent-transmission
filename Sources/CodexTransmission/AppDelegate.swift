import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel(
        controlSurface: NiTHOControlSurface(),
        agentTarget: CodexAgentTarget()
    )
    private var menuController: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuController = StatusMenuController(model: model)
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
