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

    // Finder "Open With", drag-to-Dock, and `open -a` all land here. Imports
    // run one at a time, so only the first file is taken; the rest are
    // queued until the app is idle again.
    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingOpens.append(contentsOf: urls)
        drainPendingOpens()
    }

    private var pendingOpens: [URL] = []

    @MainActor
    private func drainPendingOpens() {
        guard !pendingOpens.isEmpty else { return }
        guard AppModel.shared.phase.isIdle else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.drainPendingOpens() }
            return
        }
        let url = pendingOpens.removeFirst()
        AppModel.shared.importMeeting(from: url)
        if !pendingOpens.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.drainPendingOpens() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
