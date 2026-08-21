import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

enum NoteTab: String {
    case notes = "Notes"
    case transcript = "Transcript"
}

struct ProcessingStatus: Equatable {
    let title: String
    let detail: String
    let progress: Double?
}

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
    @Published private(set) var folders: [String] = []
    // Degraded-capture notice shown while recording (mic missing, reconnecting).
    @Published private(set) var recordingWarning: String?
    @Published private(set) var hasAPIKey = false
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var screenAuthorized = false
    @Published private(set) var calendarAuthorized = false
    @Published private(set) var microphoneIncluded = true
    @Published private(set) var systemAudioIncluded = true
    @Published private(set) var notchCollapsed = false
    @Published var settingsPresented = false
    @Published private(set) var regeneratingNoteIDs: Set<UUID> = []
    @Published var libraryAlert: String?
    @Published var noteTab: NoteTab = .notes
    @Published private(set) var searchFocusToken = 0

    // What the library's progress row and the menu bar show while the
    // pipeline is running. Nil whenever there is nothing in flight.
    var processingStatus: ProcessingStatus? {
        let title = currentSession?.candidate.appName ?? "Meeting"
        switch phase {
        case .saving:
            return ProcessingStatus(title: title, detail: "Saving audio…", progress: nil)
        case let .transcribing(progress):
            return ProcessingStatus(
                title: title,
                detail: "Transcribing — \(Int(progress * 100))%",
                progress: progress
            )
        case .analyzing:
            return ProcessingStatus(title: title, detail: "Writing notes…", progress: nil)
        default:
            return nil
        }
    }

    let settings: AppSettings

    private let store: TranscriptStore
    private let recorder: ScreenAudioRecorder
    private let transcriptionClient: TranscriptionClient
    private let analysisClient: AnalysisClient
    private var currentSession: RecordingSession?
    private var currentAudioURL: URL?
    private var currentArtifacts: RecordingArtifacts?
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
        analysisClient: AnalysisClient = AnalysisClient(),
        settings: AppSettings = AppSettings()
    ) {
#if DEBUG
        // Screenshot/demo isolation: point the whole store at a scratch root.
        let arguments = ProcessInfo.processInfo.arguments
        if let flagIndex = arguments.firstIndex(of: "--store-root"),
           arguments.indices.contains(flagIndex + 1) {
            self.store = TranscriptStore(rootURL: URL(filePath: arguments[flagIndex + 1]))
        } else {
            self.store = store
        }
#else
        self.store = store
#endif
        self.transcriptionClient = transcriptionClient
        self.analysisClient = analysisClient
        self.settings = settings
        recorder = ScreenAudioRecorder(store: self.store)
    }

    func start() {
        guard !started else { return }
        started = true

        try? store.prepareDirectories()
        reloadTranscripts()
        refreshPermissionState()
        recorder.failureHandler = { [weak self] error in
            self?.activeRecordingDidFail(error)
        }
        recorder.warningHandler = { [weak self] warning in
            self?.recordingWarning = warning?.message
        }
        recoverOrphanedRecordings()
        activityMonitor.start()
        runCaptureHarnessIfRequested()

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

    // Headless capture harness for debug builds:
    //   --start-recording                 start a manual recording after launch
    //   --stop-after <seconds>            stop it (runs the normal pipeline)
    //   --simulate-interruption-at <sec>  force the stream-restart path mid-recording
    private func runCaptureHarnessIfRequested() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--start-recording") else { return }
        func seconds(after flag: String) -> Double? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return Double(arguments[index + 1])
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            startManualRecording()
            if let at = seconds(after: "--simulate-interruption-at") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(at))
                    await recorder.simulateInterruption()
                }
            }
            if let after = seconds(after: "--stop-after") {
                try? await Task.sleep(for: .seconds(after))
                stopRecording()
            }
        }
#endif
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
                let artifacts = try await recorder.stop(expectedDuration: expectedDuration)
                currentAudioURL = artifacts.combinedURL
                currentArtifacts = artifacts
                try await processRecording(artifacts: artifacts, session: session)
            } catch {
                currentAudioURL = currentAudioURL ?? recorder.recoverableURL
                currentArtifacts = currentArtifacts ?? recorder.lastArtifacts
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
        guard let session = currentSession,
              let artifacts = currentArtifacts
                ?? recorder.lastArtifacts
                ?? (currentAudioURL ?? recorder.recoverableURL).map({
                    RecordingArtifacts(combinedURL: $0, microphoneURL: nil, systemURL: nil)
                })
        else {
            phase = .failed(message: "No recoverable audio file was found.", audioURL: nil)
            return
        }
        Task {
            do {
                try await processRecording(artifacts: artifacts, session: session)
            } catch {
                presentPendingCandidateOr(
                    .failed(message: error.localizedDescription, audioURL: artifacts.combinedURL)
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

    // MARK: - Import

    func presentImportPanel() {
        guard phase.isIdle else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a meeting recording (audio) or a transcript (.txt/.md)."
        panel.allowedContentTypes = [.audio, .plainText]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.importMeeting(from: url) }
        }
    }

    func importMeeting(from url: URL) {
        guard phase.isIdle else { return }
        switch ImportKind.classify(url) {
        case .transcript:
            importTranscript(url)
        case .audio:
            importAudio(url)
        }
    }

    private func importTranscript(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            phase = .failed(message: "The transcript file could not be read.", audioURL: nil)
            return
        }

        let session = RecordingSession(
            candidate: MeetingCandidate(
                id: "import:text",
                appName: "Imported transcript",
                bundleIdentifier: nil,
                processIdentifier: nil,
                trigger: .manual
            ),
            startedAt: Self.fileDate(of: url)
        )
        currentSession = session
        currentAudioURL = nil
        currentArtifacts = nil
        phase = .analyzing

        Task {
            do {
                let note = MeetingNote(
                    id: UUID(),
                    title: url.deletingPathExtension().lastPathComponent,
                    sourceApplication: session.candidate.appName,
                    startedAt: session.startedAt,
                    duration: 0,
                    cost: nil,
                    audioFilename: nil,
                    analysisMarkdown: nil,
                    transcriptMarkdown: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    transcriptFilename: nil
                )
                try await finalize(
                    note: note,
                    calendarEvent: nil,
                    apiKey: KeychainStore.loadAPIKey()
                )
            } catch {
                presentPendingCandidateOr(
                    .failed(message: error.localizedDescription, audioURL: nil)
                )
            }
        }
    }

    private func importAudio(_ url: URL) {
        let session = RecordingSession(
            candidate: MeetingCandidate(
                id: "import:audio",
                appName: "Imported recording",
                bundleIdentifier: nil,
                processIdentifier: nil,
                trigger: .manual
            ),
            startedAt: Self.fileDate(of: url)
        )
        currentSession = session
        phase = .saving

        Task {
            do {
                let fileExtension = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
                let copyURL = try store.newRecordingURL(extension: fileExtension, suffix: "import")
                try FileManager.default.copyItem(at: url, to: copyURL)
                let artifacts = RecordingArtifacts(
                    combinedURL: copyURL,
                    microphoneURL: nil,
                    systemURL: nil
                )
                currentAudioURL = copyURL
                currentArtifacts = artifacts
                try await processRecording(artifacts: artifacts, session: session)
            } catch {
                presentPendingCandidateOr(
                    .failed(message: error.localizedDescription, audioURL: currentAudioURL)
                )
            }
        }
    }

    private static func fileDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .now
    }

    // MARK: - Library

    func reloadTranscripts() {
        transcripts = store.loadTranscripts()
        folders = store.folders()
    }

    func moveTranscript(_ record: TranscriptRecord, toFolder folder: String?) {
        _ = try? store.move(record, toFolder: folder)
        reloadTranscripts()
    }

    @discardableResult
    func createFolder(_ name: String) -> String? {
        let created = try? store.createFolder(name)
        reloadTranscripts()
        return created
    }

    func deleteTranscript(_ record: TranscriptRecord) {
        try? store.trash(record)
        reloadTranscripts()
    }

    func renameTranscript(_ record: TranscriptRecord, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != record.title else { return }
        do {
            _ = try store.rename(record, to: trimmed)
            reloadTranscripts()
        } catch {
            libraryAlert = "The meeting couldn't be renamed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func renameFolder(_ name: String, to newName: String) -> String? {
        do {
            let renamed = try store.renameFolder(name, to: newName)
            reloadTranscripts()
            return renamed
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            libraryAlert = "A folder named “\(newName)” already exists."
            return nil
        } catch {
            libraryAlert = "The folder couldn't be renamed: \(error.localizedDescription)"
            return nil
        }
    }

    func deleteFolder(_ name: String) {
        do {
            try store.deleteFolder(name)
            reloadTranscripts()
        } catch {
            libraryAlert = "The folder couldn't be removed: \(error.localizedDescription)"
            reloadTranscripts()
        }
    }

    // Re-runs the LLM over an existing meeting with the current prompt and
    // model. The title and folder are deliberately left alone — the user may
    // have renamed or refiled the meeting, and regeneration must not undo that.
    func regenerateNotes(for record: TranscriptRecord) {
        guard !regeneratingNoteIDs.contains(record.id) else { return }
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            libraryAlert = "Add your OpenRouter API key in Settings to write meeting notes."
            return
        }
        guard var note = store.note(for: record),
              !note.transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            libraryAlert = "This meeting has no transcript to analyze."
            return
        }
        regeneratingNoteIDs.insert(record.id)

        Task {
            do {
                let context = AnalysisContext(
                    fallbackTitle: record.title,
                    sourceApplication: record.sourceApplication,
                    startedAt: record.startedAt,
                    duration: record.duration,
                    calendarEvent: nil,
                    existingFolders: store.folders()
                )
                let (outcome, analysisCost) = try await analysisClient.analyze(
                    transcript: note.transcriptMarkdown,
                    context: context,
                    apiKey: apiKey,
                    model: settings.analysisModel,
                    instructions: settings.analysisPrompt
                )
                note.analysisMarkdown = outcome.analysisMarkdown
                if note.cost != nil || analysisCost != nil {
                    note.cost = (note.cost ?? 0) + (analysisCost ?? 0)
                }
                _ = try store.update(record, with: note)
                reloadTranscripts()
            } catch {
                libraryAlert = "Notes couldn't be regenerated: \(error.localizedDescription)"
            }
            regeneratingNoteIDs.remove(record.id)
        }
    }

    func requestSearchFocus() {
        searchFocusToken += 1
    }

    // MARK: - Obsidian vault link

    var obsidianVaultURL: URL? {
        settings.obsidianVaultPath.isEmpty ? nil : URL(filePath: settings.obsidianVaultPath)
    }

    var obsidianVaultLinked: Bool {
        guard let vault = obsidianVaultURL else { return false }
        return ObsidianVaultLink.isLinked(vaultRoot: vault, transcriptsURL: store.transcriptsURL)
    }

    func linkObsidianVault(at vaultRoot: URL) throws {
        try store.prepareDirectories()
        _ = try ObsidianVaultLink.link(vaultRoot: vaultRoot, transcriptsURL: store.transcriptsURL)
        settings.obsidianVaultPath = vaultRoot.path
    }

    func unlinkObsidianVault() {
        if let vault = obsidianVaultURL {
            try? ObsidianVaultLink.unlink(vaultRoot: vault, transcriptsURL: store.transcriptsURL)
        }
        settings.obsidianVaultPath = ""
    }

    func openInObsidian(_ record: TranscriptRecord) {
        guard let vault = obsidianVaultURL,
              let url = ObsidianVaultLink.openURL(for: record, vaultRoot: vault)
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Crash recovery

    // A crash mid-recording strands the captured segments in a hidden work
    // directory. Finalize them on the next launch and feed the result through
    // the normal pipeline so the meeting lands in the library. The candidate
    // list is captured synchronously — before any monitor callback can start a
    // new recording — and the sweep is skipped while a second instance of the
    // app is running, so no listed directory can still have a live writer.
    private func recoverOrphanedRecordings() {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            return
        }
        let orphans = RecordingRecovery.orphanedWorkDirectories(
            in: store.recordingsURL,
            excluding: recorder.activeWorkDirectory
        )
        guard !orphans.isEmpty else { return }

        Task {
            for directory in orphans {
                // A prompt, live recording, or a failure showing its retry UI
                // takes priority; leftovers keep until the next launch.
                switch phase {
                case .idle, .completed:
                    await recoverRecording(at: directory)
                default:
                    return
                }
            }
        }
    }

    private func recoverRecording(at directory: URL) async {
        phase = .saving
        currentSession = nil
        currentAudioURL = nil
        currentArtifacts = nil
        do {
            guard let recovered = try await RecordingRecovery.recover(
                workDirectory: directory,
                into: store
            ) else {
                presentPendingCandidateOr(.idle)
                return
            }
            let session = RecordingSession(
                candidate: MeetingCandidate(
                    id: "recovered:\(directory.lastPathComponent)",
                    appName: "Recovered",
                    bundleIdentifier: nil,
                    processIdentifier: nil,
                    trigger: .manual
                ),
                startedAt: recovered.startedAt
            )
            currentSession = session
            currentAudioURL = recovered.artifacts.combinedURL
            currentArtifacts = recovered.artifacts
            try await processRecording(artifacts: recovered.artifacts, session: session)
        } catch {
            presentPendingCandidateOr(
                .failed(message: error.localizedDescription, audioURL: currentAudioURL)
            )
        }
    }

    private func startRecording(_ candidate: MeetingCandidate) {
        microphoneIncluded = true
        systemAudioIncluded = true
        phase = .preparing(candidate)
        Task {
            do {
                try await recorder.start(candidate: candidate, microphoneID: settings.microphoneID)
                let session = RecordingSession(candidate: candidate, startedAt: .now)
                currentSession = session
                currentAudioURL = nil
                currentArtifacts = nil
                phase = .recording(session)
            } catch {
                presentPendingCandidateOr(
                    .failed(message: error.localizedDescription, audioURL: recorder.recoverableURL)
                )
            }
        }
    }

    // The full post-recording pipeline: transcribe (Me/Them tracks when both
    // exist), save the raw note immediately, then analyze, retitle, file into
    // a folder, and export. Analysis failures degrade the note, never lose it.
    private func processRecording(artifacts: RecordingArtifacts, session: RecordingSession) async throws {
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            phase = .failed(
                message: "Add your OpenRouter API key to transcribe. The audio has been kept.",
                audioURL: artifacts.combinedURL
            )
            return
        }

        phase = .transcribing(progress: 0)
        let (transcriptMarkdown, transcriptionCost) = try await transcribe(artifacts, apiKey: apiKey)

        let duration = try await AVURLAsset(url: artifacts.combinedURL).load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw RecordingError.exportFailed("The audio file is empty or unreadable.")
        }

        // Imported files carry transfer dates, not meeting times, so calendar
        // matching would confidently mistitle them — only live recordings match.
        let isImport = session.candidate.id.hasPrefix("import:")
        let calendarEvent = isImport ? nil : calendarMonitor.eventMatching(
            start: session.startedAt,
            end: session.startedAt.addingTimeInterval(duration)
        )
        let keptAudioURL = settings.keepRecordings ? artifacts.combinedURL : nil
        let note = MeetingNote(
            id: UUID(),
            title: calendarEvent?.title ?? "\(session.candidate.appName) meeting",
            sourceApplication: session.candidate.appName,
            startedAt: session.startedAt,
            duration: duration,
            cost: transcriptionCost,
            audioFilename: keptAudioURL?.lastPathComponent,
            analysisMarkdown: nil,
            transcriptMarkdown: transcriptMarkdown,
            transcriptFilename: nil
        )
        try await finalize(note: note, calendarEvent: calendarEvent, apiKey: apiKey)

        if !settings.keepRecordings {
            try? FileManager.default.removeItem(at: artifacts.combinedURL)
        }
        for trackURL in artifacts.trackURLs {
            try? FileManager.default.removeItem(at: trackURL)
        }
        currentAudioURL = keptAudioURL
        currentArtifacts = nil
    }

    // Shared tail for recordings and imports: save the raw note first, then
    // analyze, retitle, file, and export. Analysis failures degrade the note,
    // never lose it.
    private func finalize(note: MeetingNote, calendarEvent: MatchedCalendarEvent?, apiKey: String?) async throws {
        var note = note
        note.attendees = calendarEvent?.attendees ?? []
        var record = try store.save(note, folder: nil)
        note.transcriptFilename = record.markdownURL
            .deletingPathExtension().lastPathComponent + TranscriptStore.transcriptSuffix

        if settings.analysisEnabled, let apiKey {
            phase = .analyzing
            do {
                let context = AnalysisContext(
                    fallbackTitle: note.title,
                    sourceApplication: note.sourceApplication,
                    startedAt: note.startedAt,
                    duration: note.duration,
                    calendarEvent: calendarEvent,
                    existingFolders: store.folders()
                )
                let (outcome, analysisCost) = try await analysisClient.analyze(
                    transcript: note.transcriptMarkdown,
                    context: context,
                    apiKey: apiKey,
                    model: settings.analysisModel,
                    instructions: settings.analysisPrompt
                )
                if calendarEvent == nil, let title = outcome.title {
                    note.title = title
                }
                note.analysisMarkdown = outcome.analysisMarkdown
                if note.cost != nil || analysisCost != nil {
                    note.cost = (note.cost ?? 0) + (analysisCost ?? 0)
                }
                record = try store.update(record, with: note)
                if let folder = outcome.suggestedFolder {
                    _ = try? store.move(record, toFolder: folder)
                }
            } catch {
                note.analysisMarkdown = AnalysisPlaceholder.unavailable(error.localizedDescription)
                record = (try? store.update(record, with: note)) ?? record
            }
        } else if settings.analysisEnabled {
            note.analysisMarkdown = AnalysisPlaceholder.skipped
            record = (try? store.update(record, with: note)) ?? record
        }

        reloadTranscripts()
        let finalRecord = transcripts.first { $0.id == note.id } ?? record
        presentPendingCandidateOr(.completed(finalRecord))
    }

    private func transcribe(
        _ artifacts: RecordingArtifacts,
        apiKey: String
    ) async throws -> (markdown: String, cost: Double?) {
        let progressHandler: @MainActor @Sendable (Double) -> Void = { [weak self] progress in
            self?.phase = .transcribing(progress: progress)
        }

        if let microphoneURL = artifacts.microphoneURL,
           let systemURL = artifacts.systemURL,
           FileManager.default.fileExists(atPath: microphoneURL.path),
           FileManager.default.fileExists(atPath: systemURL.path) {
            let dual = try await transcriptionClient.transcribeDualTrack(
                microphoneURL: microphoneURL,
                systemURL: systemURL,
                apiKey: apiKey,
                model: settings.transcriptionModel,
                language: settings.transcriptionLanguage,
                progress: progressHandler
            )
            if !dual.isEmpty {
                return (TrackTranscriptBuilder.markdown(me: dual.me, them: dual.them), dual.cost)
            }
        }

        let single = try await transcriptionClient.transcribe(
            fileURL: artifacts.combinedURL,
            apiKey: apiKey,
            model: settings.transcriptionModel,
            language: settings.transcriptionLanguage,
            progress: progressHandler
        )
        return (single.text, single.cost)
    }

    private func activeRecordingDidFail(_ error: any Error) {
        guard case let .recording(session) = phase else { return }
        currentSession = session
        phase = .saving

        Task {
            do {
                let expectedDuration = Date().timeIntervalSince(session.startedAt)
                let artifacts = try await recorder.stop(expectedDuration: expectedDuration)
                currentAudioURL = artifacts.combinedURL
                currentArtifacts = artifacts
                presentPendingCandidateOr(
                    .failed(message: error.localizedDescription, audioURL: artifacts.combinedURL)
                )
            } catch {
                currentAudioURL = recorder.recoverableURL
                currentArtifacts = recorder.lastArtifacts
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
