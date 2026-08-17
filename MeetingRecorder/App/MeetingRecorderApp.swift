import SwiftUI

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarIcon(symbolName: menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Window("Meeting Library", id: "transcripts") {
            TranscriptHistoryView(model: model)
        }
        .defaultSize(width: 900, height: 560)
        .commands {
            LibraryCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }

    private var menuBarSymbol: String {
        if model.phase.isRecording {
            "record.circle.fill"
        } else if model.processingStatus != nil {
            "waveform.circle"
        } else {
            "record.circle"
        }
    }
}

private struct LibraryCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Meeting…", action: model.presentImportPanel)
                .keyboardShortcut("o")
                .disabled(!model.phase.isIdle)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find", action: model.requestSearchFocus)
                .keyboardShortcut("f")
        }
        CommandGroup(before: .toolbar) {
            Button("Show Notes") { model.noteTab = .notes }
                .keyboardShortcut("1")
            Button("Show Transcript") { model.noteTab = .transcript }
                .keyboardShortcut("2")
            Divider()
        }
    }
}

private struct MenuBarIcon: View {
    let symbolName: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label("Meeting Recorder", systemImage: symbolName)
            .task {
#if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if let flagIndex = arguments.firstIndex(of: "--import"),
                   arguments.indices.contains(flagIndex + 1) {
                    AppModel.shared.importMeeting(from: URL(filePath: arguments[flagIndex + 1]))
                }
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
