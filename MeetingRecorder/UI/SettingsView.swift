import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings

    init(model: AppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        TabView {
            GeneralSettingsPane(model: model, settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            TranscriptionSettingsPane(model: model, settings: settings)
                .tabItem { Label("Transcription", systemImage: "waveform") }
            NotesSettingsPane(settings: settings)
                .tabItem { Label("Notes", systemImage: "text.document") }
        }
        .frame(width: 560)
        .onAppear(perform: model.refreshPermissionState)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissionState()
        }
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Text("Keeps meeting detection running so prompts never miss a call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use calendar meeting links as a backup", isOn: $settings.calendarBackup)
                    .onChange(of: settings.calendarBackup) {
                        Task { await model.enableCalendarBackup() }
                    }
                if settings.calendarBackup {
                    PermissionRow(title: "Calendar", authorized: model.calendarAuthorized)
                    if !model.calendarAuthorized {
                        HStack {
                            Button("Grant calendar access") {
                                Task { await model.enableCalendarBackup() }
                            }
                            Button("Open Privacy Settings", action: model.openCalendarPrivacySettings)
                        }
                    }
                }
                Text("Calendar events also name finished recordings and add attendees to meeting notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep audio after successful transcription", isOn: $settings.keepRecordings)
                Button("Show transcript folder", action: model.revealTranscripts)
                Text("Audio is always retained until transcription succeeds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranscriptionSettingsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var apiKey = ""
    @State private var keyMessage: String?

    var body: some View {
        Form {
            Section("OpenRouter") {
                LabeledContent("API key") {
                    SecureField(model.hasAPIKey ? "Saved in Keychain" : "sk-or-v1-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                HStack {
                    Button(model.hasAPIKey ? "Replace key" : "Save key") {
                        do {
                            try model.saveAPIKey(apiKey)
                            apiKey = ""
                            keyMessage = "Saved securely in Keychain."
                        } catch {
                            keyMessage = error.localizedDescription
                        }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if model.hasAPIKey {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
                if let keyMessage {
                    Text(keyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Model") {
                    TextField("openai/whisper-large-v3", text: $settings.transcriptionModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
            }

            Section("Recording access") {
                PermissionRow(title: "Microphone", authorized: model.microphoneAuthorized)
                PermissionRow(title: "Screen and system audio", authorized: model.screenAuthorized)
                if !model.microphoneAuthorized || !model.screenAuthorized {
                    HStack {
                        Button("Grant recording access") {
                            Task { await model.requestCapturePermissions() }
                        }
                        Button("Open Privacy Settings", action: model.openRecordingPrivacySettings)
                    }
                }
                Text("macOS may require the app to restart after screen and system audio access is granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotesSettingsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Write meeting notes with an LLM", isOn: $settings.analysisEnabled)
                if settings.analysisEnabled {
                    LabeledContent("Model") {
                        TextField("deepseek/deepseek-v4-pro", text: $settings.analysisModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                }
                Text("Writes detailed notes next to each transcript, names the meeting, and files it into a folder. Uses the same OpenRouter key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.analysisEnabled {
                Section("Notes prompt") {
                    TextEditor(text: $settings.analysisPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 200)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator, lineWidth: 1)
                        )
                    HStack {
                        Text("Sections, tone, language, and detail level are yours to change. Titling and folder filing keep working. Test edits by importing a transcript.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to default") {
                            settings.analysisPrompt = AnalysisClient.defaultInstructions
                        }
                        .disabled(settings.analysisPrompt == AnalysisClient.defaultInstructions)
                    }
                }

                Section("Obsidian") {
                    Toggle("Copy finished notes into an Obsidian folder", isOn: $settings.obsidianExportEnabled)
                        .onChange(of: settings.obsidianExportEnabled) {
                            if settings.obsidianExportEnabled, settings.obsidianExportPath.isEmpty {
                                settings.obsidianExportPath = AppSettings.defaultObsidianExportPath
                            }
                        }
                    if settings.obsidianExportEnabled {
                        LabeledContent("Vault folder") {
                            HStack {
                                TextField("Path", text: $settings.obsidianExportPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Choose…") {
                                    let panel = NSOpenPanel()
                                    panel.canChooseFiles = false
                                    panel.canChooseDirectories = true
                                    panel.canCreateDirectories = true
                                    if panel.runModal() == .OK, let url = panel.url {
                                        settings.obsidianExportPath = url.path
                                    }
                                }
                            }
                            .frame(width: 300)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let title: String
    let authorized: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Label(
                authorized ? "Allowed" : "Needs access",
                systemImage: authorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .foregroundStyle(authorized ? .green : .orange)
        }
    }
}
