import SwiftUI

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Label("Meeting Recorder", systemImage: model.phase.isRecording ? "record.circle.fill" : "record.circle")
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
