import AppKit

// Offers to move the app into /Applications when it is launched from a DMG,
// Downloads, or an app-translocated path. This app's permissions (microphone,
// screen recording) and Launch at Login are tied to a stable install path, so
// running it in place from a disk image quietly breaks both.
enum AppRelocator {
    static func offerMoveIfNeeded() -> Bool {
#if DEBUG
        return false
#else
        let bundleURL = Bundle.main.bundleURL
        let path = bundleURL.path

        let isInstalled = path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        let isTranslocated = path.contains("/AppTranslocation/")
        guard !isInstalled || isTranslocated else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Meeting Recorder to Applications?"
        alert.informativeText = "Meeting Recorder needs a permanent home in Applications so macOS keeps its microphone and screen-recording permissions and it can launch at login. It will move itself and reopen."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return true
        }

        let destination = URL(filePath: "/Applications/\(bundleURL.lastPathComponent)")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: bundleURL, to: destination)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Could not move the app"
            failure.informativeText = "\(error.localizedDescription)\n\nDrag Meeting Recorder into Applications in Finder, then open it from there."
            failure.runModal()
            NSApp.terminate(nil)
            return true
        }

        // Original stays behind when it is not deletable (e.g. a read-only
        // disk image); relaunch from the installed copy either way.
        try? FileManager.default.removeItem(at: bundleURL)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
#endif
    }
}
