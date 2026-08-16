import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if AppRelocator.offerMoveIfNeeded() { return }
        notchController = NotchPanelController(model: .shared)
        notchController?.show()
        AppModel.shared.start()

        let isDemo = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--demo-") }
        if AppModel.shared.settingsPresented, !isDemo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
