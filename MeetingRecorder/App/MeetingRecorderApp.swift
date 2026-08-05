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

        Window("Transcripts", id: "transcripts") {
            TranscriptHistoryView(model: model)
        }
        .defaultSize(width: 720, height: 520)

        Settings {
            SettingsView(model: model)
        }
    }
}
