import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var phase: RecorderPhase = .idle {
        didSet {
            guard oldValue != phase else { return }
            switch (oldValue, phase) {
            case (_, .idle):
                notchCollapsed = false
            case (.prompt, .prompt),
                 (.recording, .recording),
                 (.completed, .completed),
                 (.failed, .failed):
                break
            case (_, .prompt), (_, .recording), (_, .completed), (_, .failed):
                notchCollapsed = false
            default:
                break
            }
        }
    }
    @Published private(set) var transcripts: [TranscriptRecord] = []
    @Published private(set) var hasAPIKey = false
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var screenAuthorized = false
    @Published private(set) var calendarAuthorized = false
    @Published private(set) var microphoneIncluded = true
    @Published private(set) var systemAudioIncluded = true
    @Published private(set) var notchCollapsed = false
    @Published var settingsPresented = false

    let settings: AppSettings

    private let store: TranscriptStore
    private let recorder: ScreenAudioRecorder
    private let transcriptionClient: TranscriptionClient
    private var currentSession: RecordingSession?
    private var currentAudioURL: URL?
    private var pendingCandidate: MeetingCandidate?
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
        recorder.failureHandler = { [weak self] error in
            self?.activeRecordingDidFail(error)
        }
        activityMonitor.start()

        if settings.launchAtLogin {
            setLaunchAtLogin(true)
        }
        if settings.calendarBackup {
            Task { await enableCalendarBackup() }
        }

        if !hasAPIKey
            || !microphoneAuthorized
            || !screenAuthorized
            || (settings.calendarBackup && !calendarAuthorized)
        {
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
            phase = .prompt(demoCandidate)
        }
#endif
    }

    func offer(_ candidate: MeetingCandidate) {
        switch phase.offerAction(for: candidate, currentSession: currentSession) {
        case .present:
            phase = .prompt(candidate)
        case .ignore:
            return
        case .queue:
            if pendingCandidate?.id != candidate.id {
                pendingCandidate = candidate
            }
        }
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
        if candidate.trigger == .browser || candidate.trigger == .nativeApp {
            activityMonitor.suppress(candidateID: candidate.id)
        }
        presentPendingCandidateOr(.idle)
    }

    func stopRecording() {
        guard case let .recording(session) = phase else { return }
        currentSession = session
        phase = .saving

        Task {
            do {
                let expectedDuration = Date().timeIntervalSince(session.startedAt)
                let audioURL = try await recorder.stop(expectedDuration: expectedDuration)
                currentAudioURL = audioURL
                try await transcribe(audioURL: audioURL, session: session)
            } catch {
                currentAudioURL = currentAudioURL ?? recorder.recoverableURL
                presentPendingCandidateOr(
                    .failed(
                        message: error.localizedDescription,
                        audioURL: currentAudioURL
                    )
                )
            }
        }
    }

    func toggleMicrophoneIncluded() {
        guard phase.isRecording else { return }
        microphoneIncluded.toggle()
        recorder.setMicrophoneIncluded(microphoneIncluded)
    }

    func toggleSystemAudioIncluded() {
        guard phase.isRecording else { return }
        systemAudioIncluded.toggle()
        recorder.setSystemAudioIncluded(systemAudioIncluded)
    }

    func collapseOrDismissNotch() {
        switch phase {
        case .prompt:
            dismissPrompt()
        case .completed, .failed:
            dismissStatus()
        case .idle:
            break
        default:
            notchCollapsed = true
        }
    }

    func expandNotch() {
        guard !phase.isIdle else { return }
        notchCollapsed = false
    }

    func retryTranscription() {
        guard let audioURL = currentAudioURL ?? recorder.recoverableURL,
              let session = currentSession
        else {
            phase = .failed(message: "No recoverable audio file was found.", audioURL: nil)
            return
        }
        Task {
            do {
                try await transcribe(audioURL: audioURL, session: session)
            } catch {
                presentPendingCandidateOr(
                    .failed(message: error.localizedDescription, audioURL: audioURL)
                )
            }
        }
    }

    func dismissStatus() {
        presentPendingCandidateOr(.idle)
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

    func openRecordingPrivacySettings() {
        if !microphoneAuthorized {
            openPrivacySettings(pane: "Privacy_Microphone")
        } else {
            openPrivacySettings(pane: "Privacy_ScreenCapture")
        }
    }

    func enableCalendarBackup() async {
        guard settings.calendarBackup else {
            calendarMonitor.stop()
            refreshPermissionState()
            return
        }
        calendarAuthorized = await calendarMonitor.requestAccessAndStart()
        if !calendarAuthorized {
            calendarMonitor.stop()
        }
    }

    func openCalendarPrivacySettings() {
        openPrivacySettings(pane: "Privacy_Calendars")
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
        microphoneIncluded = true
        systemAudioIncluded = true
        phase = .preparing(candidate)
        Task {
            do {
                try await recorder.start(candidate: candidate)
                let session = RecordingSession(candidate: candidate, startedAt: .now)
                currentSession = session
                currentAudioURL = nil
                phase = .recording(session)
            } catch {
                presentPendingCandidateOr(
                    .failed(message: error.localizedDescription, audioURL: recorder.recoverableURL)
                )
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

        let duration = try await AVURLAsset(url: audioURL).load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw RecordingError.exportFailed
        }
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
        presentPendingCandidateOr(.completed(record))
    }

    private func activeRecordingDidFail(_ error: any Error) {
        guard case let .recording(session) = phase else { return }
        currentSession = session
        phase = .saving

        Task {
            do {
                let expectedDuration = Date().timeIntervalSince(session.startedAt)
                let audioURL = try await recorder.stop(expectedDuration: expectedDuration)
                currentAudioURL = audioURL
                presentPendingCandidateOr(
                    .failed(message: error.localizedDescription, audioURL: audioURL)
                )
            } catch {
                currentAudioURL = recorder.recoverableURL
                presentPendingCandidateOr(
                    .failed(message: error.localizedDescription, audioURL: currentAudioURL)
                )
            }
        }
    }

    private func presentPendingCandidateOr(_ fallback: RecorderPhase) {
        if let pendingCandidate {
            self.pendingCandidate = nil
            phase = .prompt(pendingCandidate)
        } else {
            phase = fallback
        }
    }

    func refreshPermissionState() {
        hasAPIKey = KeychainStore.loadAPIKey()?.isEmpty == false
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screenAuthorized = CGPreflightScreenCaptureAccess()
        calendarAuthorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        if settings.calendarBackup, calendarAuthorized {
            calendarMonitor.start()
        } else {
            calendarMonitor.stop()
        }
    }

    private func openPrivacySettings(pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
