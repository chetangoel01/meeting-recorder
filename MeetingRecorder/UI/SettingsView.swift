import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    @State private var apiKey = ""
    @State private var keyMessage: String?

    init(model: AppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        Form {
            Section("OpenRouter") {
                LabeledContent("API key") {
                    SecureField(model.hasAPIKey ? "Saved in Keychain" : "sk-or-v1-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
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
                TextField("Transcription model", text: $settings.transcriptionModel)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Recording access") {
                permissionRow("Microphone", authorized: model.microphoneAuthorized)
                permissionRow("Screen and system audio", authorized: model.screenAuthorized)
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

            Section("Reliability") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Toggle("Use calendar meeting links as a backup", isOn: $settings.calendarBackup)
                    .onChange(of: settings.calendarBackup) {
                        Task { await model.enableCalendarBackup() }
                    }
                if settings.calendarBackup {
                    permissionRow("Calendar", authorized: model.calendarAuthorized)
                    if !model.calendarAuthorized {
                        HStack {
                            Button("Grant calendar access") {
                                Task { await model.enableCalendarBackup() }
                            }
                            Button("Open Calendar Privacy Settings", action: model.openCalendarPrivacySettings)
                        }
                    }
                }
            }

            Section("Meeting notes") {
                Toggle("Analyze transcripts with an LLM", isOn: $settings.analysisEnabled)
                if settings.analysisEnabled {
                    TextField("Analysis model", text: $settings.analysisModel)
                        .textFieldStyle(.roundedBorder)
                    Text("Writes detailed meeting notes next to each transcript, names the meeting, and files it into a folder. Uses the same OpenRouter key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Notes prompt") {
                        VStack(alignment: .trailing, spacing: 6) {
                            TextEditor(text: $settings.analysisPrompt)
                                .font(.system(.caption, design: .monospaced))
                                .frame(height: 150)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                            Button("Reset to default") {
                                settings.analysisPrompt = AnalysisClient.defaultInstructions
                            }
                            .disabled(settings.analysisPrompt == AnalysisClient.defaultInstructions)
                        }
                    }
                    Text("Edit how notes are written — sections, tone, language, level of detail. The meeting title and folder still come back automatically. Test changes by importing a transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    TextField("Vault folder path", text: $settings.obsidianExportPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.obsidianExportPath = url.path
                        }
                    }
                }
            }

            Section("Storage") {
                Toggle("Keep audio after successful transcription", isOn: $settings.keepRecordings)
                Button("Show transcript folder", action: model.revealTranscripts)
                Text("Audio is always retained until transcription succeeds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(10)
        .frame(width: 480, height: 520)
        .onAppear(perform: model.refreshPermissionState)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissionState()
        }
    }

    private func permissionRow(_ title: String, authorized: Bool) -> some View {
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
