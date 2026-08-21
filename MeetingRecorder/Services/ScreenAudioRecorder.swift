import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

enum RecordingError: LocalizedError {
    case alreadyRecording
    case noDisplay
    case couldNotCreateRecording
    case microphonePermissionDenied
    case screenPermissionDenied
    case noAudioCaptured
    case captureInterrupted(String)
    case durationMismatch(expected: TimeInterval, actual: TimeInterval)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already in progress."
        case .noDisplay:
            return "No display is available to capture meeting audio."
        case .couldNotCreateRecording:
            return "The recording output could not be created."
        case .microphonePermissionDenied:
            return "Microphone access is required to record your side of the meeting."
        case .screenPermissionDenied:
            return "Screen and system audio access is required to record other participants."
        case .noAudioCaptured:
            return "Recording stopped because no call audio was arriving."
        case let .captureInterrupted(message):
            return "Recording stopped when audio capture failed: \(message) Partial audio was kept."
        case let .durationMismatch(expected, actual):
            return "The saved audio is only \(Self.duration(actual)) of a \(Self.duration(expected)) recording. Partial audio was kept."
        case let .exportFailed(reason):
            return "The captured meeting could not be converted to an audio file: \(reason)"
        }
    }

    private static func duration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct RecordingDurationValidator {
    static func isComplete(expected: TimeInterval, actual: TimeInterval) -> Bool {
        guard expected >= 15 else { return actual >= max(1, expected - 3) }
        let permittedShortfall = max(8, expected * 0.03)
        return actual + permittedShortfall >= expected
    }
}

// The combined file is the retained recording; the per-source tracks share its
// timeline origin and exist only to attribute transcript lines to Me or Them.
struct RecordingArtifacts: Sendable {
    let combinedURL: URL
    let microphoneURL: URL?
    let systemURL: URL?

    var trackURLs: [URL] {
        [microphoneURL, systemURL].compactMap { $0 }
    }
}

enum CaptureWarning: Equatable, Sendable {
    case microphoneUnavailable
    case microphonePermissionDenied
    case microphoneLost
    case reconnecting

    var message: String {
        switch self {
        case .microphoneUnavailable: return "No microphone — recording call audio only"
        case .microphonePermissionDenied: return "Microphone access denied — recording call audio only"
        case .microphoneLost: return "Microphone lost — recording call audio only"
        case .reconnecting: return "Audio capture interrupted — reconnecting…"
        }
    }
}

@MainActor
final class ScreenAudioRecorder: NSObject, SCStreamDelegate {
    typealias FailureHandler = @MainActor @Sendable (any Error) -> Void
    typealias WarningHandler = @MainActor @Sendable (CaptureWarning?) -> Void

    private static let logger = Logger(
        subsystem: "com.chetangoel.MeetingRecorder",
        category: "Capture"
    )

    private let store: TranscriptStore
    private var stream: SCStream?
    private var captureOutput: SegmentedAudioCapture?
    private var workDirectory: URL?
    private var healthTask: Task<Void, Never>?
    private var captureFailure: (any Error)?
    private var isStopping = false
    private var hasStartedHealthyCapture = false
    private var isRestarting = false
    private var restartCount = 0
    // Bumped whenever a session ends so a restart that outlives it can tell.
    private var sessionGeneration = 0
    private var wantsMicrophone = false
    private var microphoneAvailable = false
    private var preferredMicrophoneID = ""
    private var candidateName = ""
    private var currentWarning: CaptureWarning?
    private(set) var recoverableURL: URL?
    private(set) var lastArtifacts: RecordingArtifacts?
    var failureHandler: FailureHandler?
    var warningHandler: WarningHandler?

    init(store: TranscriptStore) {
        self.store = store
    }

    var isRecording: Bool { stream != nil }

    // Exposed so the launch-time orphan sweep can never mistake the live
    // recording's segment directory for a leftover from a crash.
    var activeWorkDirectory: URL? { workDirectory }

    func setMicrophoneIncluded(_ included: Bool) {
        captureOutput?.setIncluded(included, source: .microphone)
    }

    func setSystemAudioIncluded(_ included: Bool) {
        captureOutput?.setIncluded(included, source: .system)
    }

    func requestPermissions() async -> Bool {
        let microphoneGranted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        case .notDetermined:
            microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            microphoneGranted = false
        }

        let screenGranted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        return microphoneGranted && screenGranted
    }

    struct MicrophoneDevice: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    // Attached input devices, deduplicated by uniqueID — Continuity
    // microphones can be listed twice by the discovery session.
    nonisolated static func availableMicrophones() -> [MicrophoneDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        var seen = Set<String>()
        return session.devices.compactMap { device in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            return MicrophoneDevice(id: device.uniqueID, name: device.localizedName)
        }
    }

    // Resolves the configured microphone to one that is attached right now.
    // Returns nil for "system default" and for a device that has gone away.
    nonisolated static func resolveMicrophone(preferredID: String) -> MicrophoneDevice? {
        guard !preferredID.isEmpty else { return nil }
        return availableMicrophones().first { $0.id == preferredID }
    }

    // Call audio is the spine of a recording: the stream must deliver system
    // samples before recording is considered started. The microphone is
    // optional — no input device, denied permission, or a device the stream
    // rejects all degrade to a call-audio-only recording with a visible
    // warning instead of failing. Everything here is also used by
    // restartStream, which recovers from display loss, sleep, and device
    // removal without ending the recording.
    func start(candidate: MeetingCandidate, microphoneID: String = "") async throws {
        guard stream == nil else { throw RecordingError.alreadyRecording }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw RecordingError.screenPermissionDenied
        }
        let microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        try store.prepareDirectories()
        let workDirectory = store.recordingsURL.appending(
            path: "\(RecordingRecovery.workDirectoryPrefix)\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let captureOutput = SegmentedAudioCapture(workDirectory: workDirectory) { [weak self] error in
            Task { @MainActor in self?.captureDidFail(error) }
        }

        self.workDirectory = workDirectory
        self.captureOutput = captureOutput
        self.candidateName = candidate.appName
        self.preferredMicrophoneID = microphoneID
        self.wantsMicrophone = microphoneAuthorized
        captureFailure = nil
        recoverableURL = nil
        isStopping = false
        isRestarting = false
        hasStartedHealthyCapture = false
        microphoneAvailable = false
        restartCount = 0

        do {
            Self.logger.info("Starting direct audio capture for \(candidate.appName, privacy: .public)")
            let opened = try await openStream(captureOutput: captureOutput)
            stream = opened
            try await captureOutput.waitForSamples(from: .system, timeout: 10)
            microphoneAvailable = try await Self.awaitMicrophone(captureOutput, wanted: wantsMicrophone)
            hasStartedHealthyCapture = true
            startHealthMonitor(for: captureOutput)
            publishWarning(
                microphoneAvailable ? nil : (microphoneAuthorized ? .microphoneUnavailable : .microphonePermissionDenied)
            )
            Self.logger.info(
                "Call audio flowing; microphone \(self.microphoneAvailable ? "flowing" : "unavailable", privacy: .public) (authorized: \(microphoneAuthorized, privacy: .public), wanted: \(self.wantsMicrophone, privacy: .public))"
            )
        } catch {
            Self.logger.error("Capture startup failed: \(error.localizedDescription, privacy: .public)")
            await cancel()
            throw error
        }
    }

    private static func awaitMicrophone(_ captureOutput: SegmentedAudioCapture, wanted: Bool) async throws -> Bool {
        guard wanted else { return false }
        return try await captureOutput.waitForSamples(from: .microphone, timeout: 3, throwing: false)
    }

    // Builds and starts a stream on the best available display. If the
    // microphone configuration is what the stream rejects, retries without it
    // so a broken or missing input device never blocks call-audio capture.
    private func openStream(captureOutput: SegmentedAudioCapture) async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = Self.captureDisplay(in: content) else {
            throw RecordingError.noDisplay
        }
        // Capture the display's audio instead of filtering to a process. Browser audio often
        // originates in a helper process, so app filtering can silently omit the other speakers.
        let ownBundleID = Bundle.main.bundleIdentifier
        let excluded = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excluded,
            exceptingWindows: []
        )

        var attempts: [Bool] = wantsMicrophone ? [true, false] : [false]
        var lastError: (any Error)?
        while let includeMicrophone = attempts.first {
            attempts.removeFirst()
            let configuration = SCStreamConfiguration()
            configuration.width = 16
            configuration.height = 16
            configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
            configuration.queueDepth = 2
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.showsCursor = false
            configuration.captureMicrophone = includeMicrophone
            if includeMicrophone {
                if let microphone = Self.resolveMicrophone(preferredID: preferredMicrophoneID) {
                    configuration.microphoneCaptureDeviceID = microphone.id
                    Self.logger.info("Recording from microphone \(microphone.name, privacy: .public)")
                } else if !preferredMicrophoneID.isEmpty {
                    Self.logger.error("Configured microphone \(self.preferredMicrophoneID, privacy: .public) is not attached; using the system default")
                }
            }

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            do {
                try stream.addStreamOutput(captureOutput, type: .audio, sampleHandlerQueue: captureOutput.sampleQueue)
                if includeMicrophone {
                    try stream.addStreamOutput(captureOutput, type: .microphone, sampleHandlerQueue: captureOutput.sampleQueue)
                }
                try await stream.startCapture()
                if !includeMicrophone, wantsMicrophone {
                    Self.logger.error("Stream rejected the microphone configuration; capturing call audio only until the next restart")
                }
                return stream
            } catch {
                lastError = error
                Self.logger.error("Stream start failed (microphone: \(includeMicrophone, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                try? stream.removeStreamOutput(captureOutput, type: .audio)
                try? stream.removeStreamOutput(captureOutput, type: .microphone)
            }
        }
        throw lastError ?? RecordingError.couldNotCreateRecording
    }

#if DEBUG
    func simulateInterruption() async {
        await restartStream(reason: "simulated interruption")
    }
#endif

    // Recovers a stream that died or stalled: display unplugged or lid
    // closed, sleep/wake, or an input device that went away. The capture
    // output (and its segment files) survive; the new stream just resumes
    // delivering into it, and the merge pads the gap with silence.
    private func restartStream(reason: String) async {
        guard stream != nil, !isStopping, !isRestarting, captureFailure == nil,
              let captureOutput else { return }
        isRestarting = true
        defer { isRestarting = false }
        restartCount += 1
        let generation = sessionGeneration
        Self.logger.error("Audio capture interrupted (\(reason, privacy: .public)); restarting (attempt series \(self.restartCount, privacy: .public))")
        publishWarning(.reconnecting)

        if let old = stream {
            try? await old.stopCapture()
            try? old.removeStreamOutput(captureOutput, type: .audio)
            try? old.removeStreamOutput(captureOutput, type: .microphone)
        }

        var lastError: (any Error)?
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(1 << attempt))
            }
            guard !isStopping, generation == sessionGeneration else { return }
            do {
                let opened = try await openStream(captureOutput: captureOutput)
                guard !isStopping, generation == sessionGeneration else {
                    try? await opened.stopCapture()
                    return
                }
                stream = opened
                captureOutput.resetStallClock()
                try await captureOutput.waitForSamples(from: .system, timeout: 10)
                microphoneAvailable = try await Self.awaitMicrophone(captureOutput, wanted: wantsMicrophone)
                guard generation == sessionGeneration else { return }
                publishWarning(microphoneAvailable ? nil : .microphoneUnavailable)
                Self.logger.info("Audio capture restored after \(attempt + 1, privacy: .public) attempt(s)")
                return
            } catch {
                lastError = error
                Self.logger.error("Restart attempt \(attempt + 1, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard generation == sessionGeneration else { return }
        captureDidFail(AudioCaptureError.streamLost(lastError?.localizedDescription ?? reason))
    }

    func stop(expectedDuration: TimeInterval) async throws -> RecordingArtifacts {
        guard let captureOutput, let workDirectory else {
            throw RecordingError.couldNotCreateRecording
        }

        isStopping = true
        healthTask?.cancel()
        healthTask = nil
        let reportedCaptureFailure = captureFailure

        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                Self.logger.error("SCStream stop failed; finalizing captured chunks: \(error.localizedDescription, privacy: .public)")
            }
            try? stream.removeStreamOutput(captureOutput, type: .audio)
            try? stream.removeStreamOutput(captureOutput, type: .microphone)
        }

        let result = await captureOutput.finish()
        clearState()

        guard !result.segments.isEmpty else {
            try? FileManager.default.removeItem(at: workDirectory)
            throw reportedCaptureFailure ?? result.failure ?? RecordingError.noAudioCaptured
        }

        // All three mixes share one timeline origin so transcript timestamps
        // from the per-source tracks line up with the combined recording.
        let origin = result.segments.map(\.sourceStartTime).min() ?? .zero
        let audioURL = try store.newRecordingURL(extension: "m4a")
        do {
            try await Self.mixAudioSegments(
                result.segments,
                origin: origin,
                minimumDuration: expectedDuration,
                to: audioURL
            )
            recoverableURL = audioURL
        } catch {
            recoverableURL = result.segments.first?.url
            Self.logger.error("Audio merge failed: \(error.localizedDescription, privacy: .public)")
            if let recordingError = error as? RecordingError { throw recordingError }
            throw RecordingError.exportFailed(error.localizedDescription)
        }

        let artifacts = RecordingArtifacts(
            combinedURL: audioURL,
            microphoneURL: await Self.mixTrack(.microphone, from: result.segments, origin: origin, store: store),
            systemURL: await Self.mixTrack(.system, from: result.segments, origin: origin, store: store)
        )
        lastArtifacts = artifacts
        try? FileManager.default.removeItem(at: workDirectory)

        let actualDuration = try await Self.duration(of: audioURL)
        Self.logger.info(
            "Finalized recording. expected=\(expectedDuration, privacy: .public)s actual=\(actualDuration, privacy: .public)s segments=\(result.segments.count, privacy: .public)"
        )

        if let failure = reportedCaptureFailure ?? result.failure {
            throw RecordingError.captureInterrupted(failure.localizedDescription)
        }
        guard RecordingDurationValidator.isComplete(expected: expectedDuration, actual: actualDuration) else {
            throw RecordingError.durationMismatch(expected: expectedDuration, actual: actualDuration)
        }
        return artifacts
    }

    // Per-source tracks are best-effort: a failed track mix degrades speaker
    // attribution, never the recording itself. Both sources must be present —
    // a single-source recording has nothing to attribute.
    fileprivate static func mixTrack(
        _ source: AudioSource,
        from segments: [AudioSegment],
        origin: CMTime,
        store: TranscriptStore
    ) async -> URL? {
        let sourceSegments = segments.filter { $0.source == source }
        guard !sourceSegments.isEmpty, sourceSegments.count < segments.count else { return nil }

        let suffix = source == .microphone ? "meeting-me" : "meeting-them"
        guard let url = try? store.newRecordingURL(extension: "m4a", suffix: suffix) else { return nil }
        do {
            try await Self.mixAudioSegments(sourceSegments, origin: origin, minimumDuration: 0, to: url)
            return url
        } catch {
            Self.logger.error("Track mix failed for \(source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    func cancel() async {
        isStopping = true
        healthTask?.cancel()
        healthTask = nil
        if let stream { try? await stream.stopCapture() }
        if let stream, let captureOutput {
            try? stream.removeStreamOutput(captureOutput, type: .audio)
            try? stream.removeStreamOutput(captureOutput, type: .microphone)
        }
        if let captureOutput { await captureOutput.cancel() }
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        recoverableURL = nil
        lastArtifacts = nil
        clearState()
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let stoppedStream = ObjectIdentifier(stream)
        let reason = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, let current = self.stream, ObjectIdentifier(current) == stoppedStream else { return }
            await self.restartStream(reason: reason)
        }
    }

    // Every 2 s: writer errors are fatal (disk full, file system); a stalled
    // call-audio feed means the stream is dead and gets restarted; a stalled
    // microphone gets one restart (which re-resolves the device) and then
    // degrades to call-audio-only, recovering automatically if samples return.
    private func startHealthMonitor(for captureOutput: SegmentedAudioCapture) {
        healthTask = Task { @MainActor [weak self, weak captureOutput] in
            var microphoneRestartUsed = false
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self, let captureOutput else { return }
                guard !self.isStopping, !self.isRestarting else { continue }

                if let failure = captureOutput.failure {
                    self.captureDidFail(failure)
                    return
                }
                if captureOutput.isStalled(.system, maximumSilence: 8) {
                    await self.restartStream(reason: "call audio stopped arriving")
                    continue
                }
                guard self.wantsMicrophone else { continue }
                let microphoneStalled = captureOutput.isStalled(.microphone, maximumSilence: 8)
                if self.microphoneAvailable, microphoneStalled {
                    if !microphoneRestartUsed {
                        microphoneRestartUsed = true
                        await self.restartStream(reason: "microphone stopped arriving")
                    } else {
                        self.microphoneAvailable = false
                        Self.logger.error("Microphone samples stopped; continuing with call audio only")
                        self.publishWarning(.microphoneLost)
                    }
                } else if !self.microphoneAvailable, !microphoneStalled, captureOutput.hasReceived(.microphone) {
                    self.microphoneAvailable = true
                    microphoneRestartUsed = false
                    Self.logger.info("Microphone samples resumed")
                    self.publishWarning(nil)
                }
            }
        }
    }

    private func publishWarning(_ warning: CaptureWarning?) {
        guard warning != currentWarning else { return }
        currentWarning = warning
        warningHandler?(warning)
    }

    private func captureDidFail(_ error: any Error) {
        guard stream != nil, !isStopping, captureFailure == nil else { return }
        captureFailure = error
        healthTask?.cancel()
        healthTask = nil
        Self.logger.fault("Active recording failed: \(error.localizedDescription, privacy: .public)")
        if hasStartedHealthyCapture {
            failureHandler?(error)
        }
    }

    private func clearState() {
        sessionGeneration += 1
        healthTask?.cancel()
        healthTask = nil
        stream = nil
        captureOutput = nil
        workDirectory = nil
        captureFailure = nil
        isStopping = false
        isRestarting = false
        hasStartedHealthyCapture = false
        microphoneAvailable = false
        publishWarning(nil)
    }

    private static func captureDisplay(in content: SCShareableContent) -> SCDisplay? {
        let builtInScreen = NSScreen.screens.first {
            $0.localizedName.localizedCaseInsensitiveContains("built-in")
        } ?? NSScreen.main
        let displayID = builtInScreen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID
        return content.displays.first { $0.displayID == displayID } ?? content.displays.first
    }

    fileprivate static func mixAudioSegments(
        _ segments: [AudioSegment],
        origin: CMTime,
        minimumDuration: TimeInterval,
        to destinationURL: URL
    ) async throws {
        let composition = AVMutableComposition()

        for segment in segments.sorted(by: { $0.sourceStartTime < $1.sourceStartTime }) {
            let asset = AVURLAsset(url: segment.url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let destinationTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  )
            else { continue }

            let duration = try await asset.load(.duration)
            let insertionTime = CMTimeMaximum(.zero, segment.sourceStartTime - origin)
            // Materialize the leading gap explicitly. A source excluded at the
            // start of a recording produces its first segment mid-timeline, and
            // an empty track is not guaranteed to preserve an insertion offset —
            // silently shifting every timestamp on that track earlier.
            if insertionTime > .zero {
                destinationTrack.insertEmptyTimeRange(
                    CMTimeRange(start: .zero, duration: insertionTime)
                )
            }
            try destinationTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: insertionTime
            )
        }

        let requestedDuration = CMTime(seconds: minimumDuration, preferredTimescale: 600)
        if composition.duration < requestedDuration {
            composition.insertEmptyTimeRange(
                CMTimeRange(
                    start: composition.duration,
                    duration: requestedDuration - composition.duration
                )
            )
        }

        guard !composition.tracks(withMediaType: .audio).isEmpty,
              let exporter = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetAppleM4A
              )
        else {
            throw RecordingError.exportFailed("No audio tracks could be read from the captured segments.")
        }

        try? FileManager.default.removeItem(at: destinationURL)
        do {
            try await exporter.export(to: destinationURL, as: .m4a)
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            let detail = underlying.map { " (\($0.domain) \($0.code))" } ?? ""
            throw RecordingError.exportFailed("\(error.localizedDescription)\(detail)")
        }
    }

    private static func duration(of url: URL) async throws -> TimeInterval {
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        guard seconds.isFinite else { throw RecordingError.exportFailed("The merged file has no readable duration.") }
        return seconds
    }
}

// MARK: - Crash recovery

struct RecoveredRecording: Sendable {
    let artifacts: RecordingArtifacts
    let startedAt: Date
}

// Finalizes audio stranded in segment work directories when the app (or the
// whole Mac) died mid-recording. Only this app writes those directories, so a
// sweep is safe once the caller has confirmed no second app instance is
// running and has excluded the live recording's own directory.
enum RecordingRecovery {
    static let workDirectoryPrefix = ".capture-"

    static func orphanedWorkDirectories(
        in recordingsURL: URL,
        excluding activeDirectory: URL?
    ) -> [URL] {
        // No .skipsHiddenFiles: the work directories are deliberately
        // dot-prefixed so Finder and the library never show them.
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: recordingsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return urls
            .filter { url in
                url.lastPathComponent.hasPrefix(workDirectoryPrefix)
                    && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && url.standardizedFileURL.path != activeDirectory?.standardizedFileURL.path
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func parseSegmentFilename(_ filename: String) -> (source: AudioSource, index: Int)? {
        guard filename.hasSuffix(".m4a") else { return nil }
        let stem = filename.dropLast(4)
        guard let dash = stem.lastIndex(of: "-"),
              let source = AudioSource(rawValue: String(stem[..<dash])),
              let index = Int(stem[stem.index(after: dash)...]),
              index >= 0
        else { return nil }
        return (source, index)
    }

    // Mixes whatever the crashed recording left behind into the same artifact
    // set a clean stop produces, and removes the work directory. Returns nil
    // (still cleaning up) when nothing in the directory is readable audio.
    static func recover(
        workDirectory: URL,
        into store: TranscriptStore
    ) async throws -> RecoveredRecording? {
        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: workDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: []
        )) ?? []
        let named = fileURLs.compactMap { url -> (source: AudioSource, index: Int, url: URL)? in
            guard let parsed = parseSegmentFilename(url.lastPathComponent) else { return nil }
            return (parsed.source, parsed.index, url)
        }

        // The crash destroyed the capture timeline, so rebuild each source's
        // segments back to back: a segment starts where its predecessor rolled
        // over, and both sources began together at capture start. The tail
        // segment was never finalized and usually fails to load — skip it, and
        // anything else that no longer parses as audio, keeping the rest.
        var segments: [AudioSegment] = []
        var nextStart: [AudioSource: CMTime] = [:]
        for file in named.sorted(by: { ($0.source.rawValue, $0.index) < ($1.source.rawValue, $1.index) }) {
            guard let duration = try? await AVURLAsset(url: file.url).load(.duration),
                  duration.isNumeric, duration > .zero
            else { continue }
            let start = nextStart[file.source] ?? .zero
            segments.append(AudioSegment(source: file.source, url: file.url, sourceStartTime: start))
            nextStart[file.source] = start + duration
        }

        guard !segments.isEmpty else {
            try? FileManager.default.removeItem(at: workDirectory)
            return nil
        }

        let startedAt = named
            .compactMap { try? $0.url.resourceValues(forKeys: [.creationDateKey]).creationDate }
            .min()
            ?? (try? workDirectory.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? .now

        let audioURL = try store.newRecordingURL(extension: "m4a", suffix: "recovered")
        try await ScreenAudioRecorder.mixAudioSegments(
            segments,
            origin: .zero,
            minimumDuration: 0,
            to: audioURL
        )
        let artifacts = RecordingArtifacts(
            combinedURL: audioURL,
            microphoneURL: await ScreenAudioRecorder.mixTrack(.microphone, from: segments, origin: .zero, store: store),
            systemURL: await ScreenAudioRecorder.mixTrack(.system, from: segments, origin: .zero, store: store)
        )
        try? FileManager.default.removeItem(at: workDirectory)
        return RecoveredRecording(artifacts: artifacts, startedAt: startedAt)
    }
}

enum AudioSource: String, Sendable {
    case system
    case microphone
}

private struct AudioSegment: @unchecked Sendable {
    let source: AudioSource
    let url: URL
    let sourceStartTime: CMTime
}

private struct CaptureFinishResult: @unchecked Sendable {
    let segments: [AudioSegment]
    let failure: (any Error)?
}

private final class SegmentedAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    let sampleQueue = DispatchQueue(
        label: "MeetingRecorder.AudioSamples",
        qos: .userInitiated
    )

    private let workDirectory: URL
    private let segmentDuration: TimeInterval = 2 * 60
    private let failureHandler: @Sendable (any Error) -> Void
    private let statusLock = NSLock()
    private var writers: [AudioSource: AudioSegmentWriter] = [:]
    private var finalizers: [SegmentFinalizer] = []
    private var segmentCounts: [AudioSource: Int] = [:]
    private var receivedSources: Set<AudioSource> = []
    private var lastSampleDates: [AudioSource: Date] = [:]
    private var storedFailure: (any Error)?
    private var acceptingSamples = true
    private var includedSources = Set([AudioSource.system, .microphone])

    init(
        workDirectory: URL,
        failureHandler: @escaping @Sendable (any Error) -> Void
    ) {
        self.workDirectory = workDirectory
        self.failureHandler = failureHandler
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let source = Self.source(for: outputType),
              acceptingSamples
        else { return }

        statusLock.withLock {
            receivedSources.insert(source)
            lastSampleDates[source] = .now
        }
        guard includedSources.contains(source) else { return }

        do {
            try append(sampleBuffer, source: source)
        } catch {
            reportFailure(error)
        }
    }

    func setIncluded(_ included: Bool, source: AudioSource) {
        sampleQueue.async { [self] in
            if included {
                includedSources.insert(source)
            } else {
                includedSources.remove(source)
            }
        }
    }

    var failure: (any Error)? {
        statusLock.withLock { storedFailure }
    }

    func hasReceived(_ source: AudioSource) -> Bool {
        statusLock.withLock { receivedSources.contains(source) }
    }

    // Waits for the first sample from a source. A stored writer failure is
    // always thrown; a timeout throws only when `throwing` is set, so the
    // optional microphone can be awaited without failing the recording.
    @discardableResult
    func waitForSamples(from source: AudioSource, timeout: TimeInterval, throwing: Bool = true) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (failure, ready) = statusLock.withLock {
                (storedFailure, lastSampleDates[source] != nil)
            }
            if let failure { throw failure }
            if ready { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        if throwing { throw RecordingError.noAudioCaptured }
        return false
    }

    func isStalled(_ source: AudioSource, maximumSilence: TimeInterval) -> Bool {
        statusLock.withLock {
            guard let lastSampleDate = lastSampleDates[source] else { return true }
            return Date().timeIntervalSince(lastSampleDate) > maximumSilence
        }
    }

    // After a stream restart, give every source a fresh grace period instead
    // of immediately reporting the gap the restart itself caused.
    func resetStallClock() {
        statusLock.withLock {
            for source in [AudioSource.system, .microphone] where lastSampleDates[source] != nil {
                lastSampleDates[source] = .now
            }
        }
    }

    func finish() async -> CaptureFinishResult {
        let pendingFinalizers: [SegmentFinalizer] = await withCheckedContinuation { continuation in
            sampleQueue.async { [self] in
                acceptingSamples = false
                for writer in writers.values {
                    finalizers.append(writer.beginFinish())
                }
                writers.removeAll()
                continuation.resume(returning: finalizers)
            }
        }

        var segments: [AudioSegment] = []
        var finishFailure: (any Error)?
        for finalizer in pendingFinalizers {
            switch await finalizer.wait() {
            case let .success(segment):
                segments.append(segment)
            case let .failure(error):
                finishFailure = finishFailure ?? error
            }
        }

        let failure = statusLock.withLock { storedFailure ?? finishFailure }
        return CaptureFinishResult(segments: segments, failure: failure)
    }

    func cancel() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sampleQueue.async { [self] in
                acceptingSamples = false
                for writer in writers.values {
                    writer.cancel()
                }
                writers.removeAll()
                continuation.resume()
            }
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, source: AudioSource) throws {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isNumeric else { return }

        var writer = writers[source]
        if let current = writer,
           current.elapsed(at: presentationTime) >= segmentDuration || !current.accepts(sampleBuffer) {
            finalizers.append(current.beginFinish())
            writers[source] = nil
            writer = nil
        }

        if writer == nil {
            let index = segmentCounts[source, default: 0]
            segmentCounts[source] = index + 1
            writer = try AudioSegmentWriter(
                directory: workDirectory,
                source: source,
                index: index,
                firstSample: sampleBuffer
            )
            writers[source] = writer
        }

        try writer?.append(sampleBuffer)
    }

    private func reportFailure(_ error: any Error) {
        let isFirstFailure = statusLock.withLock {
            let isFirstFailure = storedFailure == nil
            if isFirstFailure { storedFailure = error }
            return isFirstFailure
        }

        guard isFirstFailure else { return }
        acceptingSamples = false
        failureHandler(error)
    }

    private static func source(for outputType: SCStreamOutputType) -> AudioSource? {
        switch outputType {
        case .audio:
            return .system
        case .microphone:
            return .microphone
        default:
            return nil
        }
    }
}

private final class AudioSegmentWriter: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.chetangoel.MeetingRecorder", category: "Capture")


    private let segment: AudioSegment
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let sourceFormat: CMFormatDescription

    init(
        directory: URL,
        source: AudioSource,
        index: Int,
        firstSample: CMSampleBuffer
    ) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(firstSample),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              )?.pointee
        else {
            throw RecordingError.couldNotCreateRecording
        }

        // ScreenCaptureKit stamps samples with the host clock, which is what
        // lets segments from a restarted stream land at the right place on
        // the shared timeline. Guard that assumption: a stamp far from host
        // time would misplace minutes of audio, so fall back to host time.
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(firstSample)
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let drift = abs((presentationTime - hostTime).seconds)
        let startTime: CMTime
        if presentationTime.isNumeric, drift < 5 {
            startTime = presentationTime
        } else {
            Self.logger.error("Segment PTS is \(drift, privacy: .public)s from host time; using host time for placement")
            startTime = hostTime
        }
        let url = directory.appending(
            path: String(format: "%@-%04d.m4a", source.rawValue, index)
        )
        let writer = try AVAssetWriter(url: url, fileType: .m4a)
        let channelCount = max(1, min(Int(streamDescription.mChannelsPerFrame), 2))
        let outputSettings = AACEncodingSettings.outputSettings(
            sourceSampleRate: streamDescription.mSampleRate,
            channelCount: channelCount
        )
        Self.logger.info(
            "\(source.rawValue, privacy: .public) segment \(index, privacy: .public): source \(streamDescription.mSampleRate, privacy: .public) Hz x\(streamDescription.mChannelsPerFrame, privacy: .public) -> \(String(describing: outputSettings[AVSampleRateKey] ?? 0), privacy: .public) Hz x\(channelCount, privacy: .public) @ \(String(describing: outputSettings[AVEncoderBitRateKey] ?? 0), privacy: .public) bps"
        )
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.couldNotCreateRecording }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RecordingError.couldNotCreateRecording
        }
        writer.startSession(atSourceTime: startTime)

        segment = AudioSegment(source: source, url: url, sourceStartTime: startTime)
        self.writer = writer
        self.input = input
        self.sourceFormat = formatDescription
    }

    // A writer is bound to the format of its first sample. Sample-rate
    // changes are resampled, but a channel-count change (mono built-in mic
    // swapped for a stereo interface mid-call) makes append fail and takes
    // the whole recording down, so callers rotate to a new segment instead.
    func accepts(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return true }
        return AudioFormatCompatibility.isCompatible(sourceFormat, format)
    }

    func elapsed(at presentationTime: CMTime) -> TimeInterval {
        max(0, (presentationTime - segment.sourceStartTime).seconds)
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws {
        guard input.isReadyForMoreMediaData else {
            throw writer.error ?? AudioCaptureError.writerBackpressure
        }
        guard input.append(sampleBuffer) else {
            throw writer.error ?? AudioCaptureError.sampleWriteFailed
        }
    }

    func beginFinish() -> SegmentFinalizer {
        input.markAsFinished()
        let finalizer = SegmentFinalizer()
        writer.finishWriting { [self] in
            if writer.status == .completed {
                finalizer.finish(.success(segment))
            } else {
                finalizer.finish(
                    .failure(writer.error ?? RecordingError.couldNotCreateRecording)
                )
            }
        }
        return finalizer
    }

    func cancel() {
        writer.cancelWriting()
    }
}

private enum AudioCaptureError: LocalizedError {
    case samplesStopped(AudioSource)
    case streamLost(String)
    case writerBackpressure
    case sampleWriteFailed

    var errorDescription: String? {
        switch self {
        case let .samplesStopped(source):
            return "\(source.rawValue.capitalized) audio samples stopped arriving."
        case let .streamLost(reason):
            return "Audio capture stopped and could not be restarted: \(reason)"
        case .writerBackpressure:
            return "The audio writer stopped accepting samples."
        case .sampleWriteFailed:
            return "An audio sample could not be saved."
        }
    }
}

private final class SegmentFinalizer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<AudioSegment, any Error>, Never>?
    private var result: Result<AudioSegment, any Error>?

    func wait() async -> Result<AudioSegment, any Error> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<AudioSegment, any Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.result = result
            lock.unlock()
        }
    }
}

// MARK: - AAC encoding

enum AACEncodingSettings {
    // The AAC encoder rejects bitrates above roughly 3x the sample rate per
    // channel with "Cannot Encode Media" (a 16 kHz USB webcam mic at 96 kbps
    // fails; 48 kbps works), and AVAssetWriterInput raises an ObjC exception
    // for sample rates AAC cannot encode at all (88.2/96 kHz interfaces).
    // canApply(outputSettings:) reports true for both, so clamp up front.
    // AVAssetWriter resamples when the output rate differs from the source.
    static let aacSampleRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
    static let preferredBitRate = 96_000

    static func outputSettings(sourceSampleRate: Double, channelCount: Int) -> [String: Any] {
        let sampleRate = aacSampleRates.contains(sourceSampleRate) ? sourceSampleRate : 48_000
        let ceiling = Int(sampleRate) * 3 * channelCount
        let bitRate = min(preferredBitRate, ceiling)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
        ]
        // Below 16 kHz even modest bitrates are rejected; let the encoder choose.
        if sampleRate >= 16_000 {
            settings[AVEncoderBitRateKey] = bitRate
        }
        return settings
    }
}

// MARK: - Format compatibility

enum AudioFormatCompatibility {
    // Measured against AVAssetWriterInput: a different sample rate is
    // converted transparently; a different channel count fails the write.
    static func isCompatible(_ current: CMFormatDescription, _ incoming: CMFormatDescription) -> Bool {
        guard let a = CMAudioFormatDescriptionGetStreamBasicDescription(current)?.pointee,
              let b = CMAudioFormatDescriptionGetStreamBasicDescription(incoming)?.pointee
        else { return true }
        return a.mChannelsPerFrame == b.mChannelsPerFrame
    }
}
