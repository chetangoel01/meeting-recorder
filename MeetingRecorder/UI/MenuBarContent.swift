import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let status = model.processingStatus {
            Text("\(status.title): \(status.detail)")
            Divider()
        }

        if model.phase.isRecording {
            Button("Stop recording", systemImage: "stop.circle.fill", action: model.stopRecording)
        } else {
            Button("Start recording", systemImage: "record.circle", action: model.startManualRecording)
                .disabled(!isIdle)
        }

        Button("Import meeting…", systemImage: "square.and.arrow.down", action: model.presentImportPanel)
            .disabled(!isIdle)

        Divider()

        Button("Meeting library…", systemImage: "text.document") {
            openWindow(id: "transcripts")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Show transcript folder", systemImage: "folder", action: model.revealTranscripts)

        Divider()

        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }
        Button("Quit Meeting Recorder", systemImage: "power") {
            NSApp.terminate(nil)
        }
    }

    private var isIdle: Bool {
        if case .idle = model.phase { return true }
        return false
    }
}
