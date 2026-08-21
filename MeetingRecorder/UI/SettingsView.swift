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
            NotesSettingsPane(model: model, settings: settings)
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
    @State private var microphones: [ScreenAudioRecorder.MicrophoneDevice] = []

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
                Picker("Microphone", selection: $settings.microphoneID) {
                    Text("System default").tag("")
                    ForEach(microphones) { microphone in
                        Text(microphone.name).tag(microphone.id)
                    }
                    if !settings.microphoneID.isEmpty, !microphones.contains(where: { $0.id == settings.microphoneID }) {
                        Text("Previously selected (not attached)").tag(settings.microphoneID)
                    }
                }
                Text("Your side of the meeting is recorded from this microphone. If it isn't attached when a recording starts, the system default is used.")
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
        .onAppear { microphones = ScreenAudioRecorder.availableMicrophones() }
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
                SecureField(
                    "API key",
                    text: $apiKey,
                    prompt: Text(model.hasAPIKey ? "Saved in Keychain" : "sk-or-v1-…")
                )
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
                TextField(
                    "Model",
                    text: $settings.transcriptionModel,
                    prompt: Text("openai/whisper-large-v3")
                )
                Picker("Language", selection: $settings.transcriptionLanguage) {
                    ForEach(AppSettings.transcriptionLanguages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Text("Whisper picks one language per upload from its first few seconds. Pin the meeting language so a stray phrase can't flip minutes of transcript into another language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var vaultLinkMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Write meeting notes with an LLM", isOn: $settings.analysisEnabled)
                if settings.analysisEnabled {
                    TextField(
                        "Model",
                        text: $settings.analysisModel,
                        prompt: Text("deepseek/deepseek-v4-pro")
                    )
                }
                Text("Writes detailed notes next to each transcript, names the meeting, and files it into a folder. Uses the same OpenRouter key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Obsidian") {
                if let vaultURL = model.obsidianVaultURL {
                    LabeledContent("Vault") {
                        HStack(spacing: 8) {
                            Text(vaultURL.lastPathComponent)
                            if model.obsidianVaultLinked {
                                Label("Linked", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Button("Repair link") { linkVault(at: vaultURL) }
                            }
                        }
                    }
                    Button("Unlink vault") {
                        model.unlinkObsidianVault()
                        vaultLinkMessage = nil
                    }
                    Text("Your meeting library appears in the vault as a “Meetings” folder — the same files the app manages, not copies. Unlinking removes the link only; no meetings are touched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Link Obsidian vault…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.message = "Choose your Obsidian vault folder. A “Meetings” link to the meeting library will be created inside it."
                        let defaultVault = URL(filePath: AppSettings.defaultObsidianVaultPath)
                        if FileManager.default.fileExists(atPath: defaultVault.path) {
                            panel.directoryURL = defaultVault
                        }
                        if panel.runModal() == .OK, let url = panel.url {
                            linkVault(at: url)
                        }
                    }
                    Text("Puts a “Meetings” link inside your vault pointing at the meeting library, so Obsidian's navigation, search, and backlinks work on the real notes — one source of truth. Symlinked folders don't sync to Obsidian mobile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let vaultLinkMessage {
                    Text(vaultLinkMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            }

        }
        .formStyle(.grouped)
    }

    private func linkVault(at url: URL) {
        do {
            try model.linkObsidianVault(at: url)
            vaultLinkMessage = "Linked. Open Obsidian and look for the “Meetings” folder."
        } catch {
            vaultLinkMessage = "The vault couldn't be linked: \(error.localizedDescription)"
        }
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
