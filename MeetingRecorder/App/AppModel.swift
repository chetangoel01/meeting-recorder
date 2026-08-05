import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var phase: RecorderPhase = .idle
    @Published private(set) var transcripts: [TranscriptRecord] = []
    @Published private(set) var hasAPIKey = false
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var screenAuthorized = false
    @Published private(set) var calendarAuthorized = false
    @Published var settingsPresented = false

    let settings: AppSettings

    private let store: TranscriptStore
    private let recorder: ScreenAudioRecorder
    private let transcriptionClient: TranscriptionClient
    private var currentSession: RecordingSession?
    private var currentAudioURL: URL?
    private var started = false

    private lazy var activityMonitor = MeetingActivityMonitor { [weak self] candidate in
        Task { @MainActor in self?.offer(candidate) }
    }

    private lazy var calendarMonitor = CalendarMeetingMonitor { [weak self] candidate in
        self?.offer(candidate)
    }

    private init(
        store: TranscriptStore = TranscriptStore(),
        transcriptionClient: TranscriptionClient = TranscriptionClient(),
        settings: AppSettings = AppSettings()
    ) {
        self.store = store
        self.transcriptionClient = transcriptionClient
        self.settings = settings
        recorder = ScreenAudioRecorder(store: store)
    }

    func start() {
        guard !started else { return }
        started = true

        try? store.prepareDirectories()
        transcripts = store.loadTranscripts()
        refreshPermissionState()
        activityMonitor.start()

        if settings.launchAtLogin {
            setLaunchAtLogin(true)
        }
        if settings.calendarBackup {
            Task { await enableCalendarBackup() }
        }

        if !hasAPIKey || !microphoneAuthorized || !screenAuthorized {
            settingsPresented = true
        }

#if DEBUG
        let demoCandidate = MeetingCandidate(
            id: "demo:arc",
            appName: "Google Meet in Arc",
            bundleIdentifier: "company.thebrowser.Browser",
            processIdentifier: nil,
            trigger: .browser
        )
        if ProcessInfo.processInfo.arguments.contains("--demo-recording") {
            phase = .recording(
                RecordingSession(candidate: demoCandidate, startedAt: .now.addingTimeInterval(-67))
            )
        } else if ProcessInfo.processInfo.arguments.contains("--demo-prompt") {
            offer(demoCandidate)
        }
#endif
    }

    func offer(_ candidate: MeetingCandidate) {
        guard case .idle = phase else { return }
        phase = .prompt(candidate)
    }

    func recordPromptedMeeting() {
        guard case let .prompt(candidate) = phase else { return }
        startRecording(candidate)
    }

    func startManualRecording() {
        guard case .idle = phase else { return }
        startRecording(.manual)
    }

    func dismissPrompt() {
        guard case let .prompt(candidate) = phase else { return }
        activityMonitor.suppress(candidateID: candidate.id)
        phase = .idle
    }

    func stopRecording() {
        guard case let .recording(session) = phase else { return }
        currentSession = session
        phase = .saving

        Task {
            do {
                let audioURL = try await recorder.stop()
                currentAudioURL = audioURL
                try await transcribe(audioURL: audioURL, session: session)
            } catch {
                phase = .failed(
                    message: error.localizedDescription,
                    audioURL: currentAudioURL ?? recorder.recoverableURL
                )
            }
        }
    }

    func retryTranscription() {
        guard let audioURL = currentAudioURL ?? recorder.recoverableURL,
              let session = currentSession
        else {
            phase = .failed(message: "No recoverable audio file was found.", audioURL: nil)
            return
        }
        Task { try? await transcribe(audioURL: audioURL, session: session) }
    }

    func dismissStatus() {
        phase = .idle
    }

    func saveAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try KeychainStore.deleteAPIKey()
        } else {
            try KeychainStore.saveAPIKey(trimmed)
        }
        refreshPermissionState()
    }

    func requestCapturePermissions() async {
        _ = await recorder.requestPermissions()
        refreshPermissionState()
    }

    func enableCalendarBackup() async {
        guard settings.calendarBackup else {
            calendarMonitor.stop()
            refreshPermissionState()
            return
        }
        calendarAuthorized = await calendarMonitor.requestAccessAndStart()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        settings.launchAtLogin = enabled
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func revealTranscripts() {
        try? store.prepareDirectories()
        NSWorkspace.shared.activateFileViewerSelecting([store.transcriptsURL])
    }

    func revealAudio(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyTranscript(_ record: TranscriptRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
    }

    private func startRecording(_ candidate: MeetingCandidate) {
        phase = .preparing(candidate)
        Task {
            do {
                try await recorder.start(candidate: candidate)
                let session = RecordingSession(candidate: candidate, startedAt: .now)
                currentSession = session
                currentAudioURL = nil
                phase = .recording(session)
            } catch {
                phase = .failed(message: error.localizedDescription, audioURL: recorder.recoverableURL)
            }
        }
    }

    private func transcribe(audioURL: URL, session: RecordingSession) async throws {
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            phase = .failed(
                message: "Add your OpenRouter API key to transcribe. The audio has been kept.",
                audioURL: audioURL
            )
            return
        }

        phase = .transcribing(progress: 0)
        let result = try await transcriptionClient.transcribe(
            fileURL: audioURL,
            apiKey: apiKey,
            model: settings.transcriptionModel
        ) { [weak self] progress in
            self?.phase = .transcribing(progress: progress)
        }

        let duration = Date().timeIntervalSince(session.startedAt)
        let keptAudioURL = settings.keepRecordings ? audioURL : nil
        let title = "\(session.candidate.appName) meeting"
        let record = try store.saveTranscript(
            title: title,
            sourceApplication: session.candidate.appName,
            startedAt: session.startedAt,
            duration: duration,
            text: result.text,
            cost: result.cost,
            audioURL: keptAudioURL
        )
        if !settings.keepRecordings {
            try? FileManager.default.removeItem(at: audioURL)
        }

        currentAudioURL = keptAudioURL
        transcripts.insert(record, at: 0)
        phase = .completed(record)
    }

    private func refreshPermissionState() {
        hasAPIKey = KeychainStore.loadAPIKey()?.isEmpty == false
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenAuthorized = CGPreflightScreenCaptureAccess()
        calendarAuthorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }
}
