import SwiftUI

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarIcon(isRecording: model.phase.isRecording)
        }
        .menuBarExtraStyle(.menu)

        Window("Meeting Library", id: "transcripts") {
            TranscriptHistoryView(model: model)
        }
        .defaultSize(width: 900, height: 560)

        Settings {
            SettingsView(model: model)
        }
    }
}

private struct MenuBarIcon: View {
    let isRecording: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label("Meeting Recorder", systemImage: isRecording ? "record.circle.fill" : "record.circle")
            .task {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--demo-library") {
                    openWindow(id: "transcripts")
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        NSApp.windows
                            .first { $0.title == "Meeting Library" }?
                            .setFrame(NSRect(x: 306, y: 200, width: 900, height: 560), display: true)
                    }
                }
#endif
            }
    }
}
