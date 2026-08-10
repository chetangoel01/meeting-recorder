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
    case exportFailed

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
            return "Recording stopped because no microphone or call audio was arriving."
        case let .captureInterrupted(message):
            return "Recording stopped when audio capture failed: \(message) Partial audio was kept."
        case let .durationMismatch(expected, actual):
            return "The saved audio is only \(Self.duration(actual)) of a \(Self.duration(expected)) recording. Partial audio was kept."
        case .exportFailed:
            return "The captured meeting could not be converted to an audio file."
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

@MainActor
final class ScreenAudioRecorder: NSObject, SCStreamDelegate {
    typealias FailureHandler = @MainActor @Sendable (any Error) -> Void

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
    private(set) var recoverableURL: URL?
    private(set) var lastArtifacts: RecordingArtifacts?
    var failureHandler: FailureHandler?

    init(store: TranscriptStore) {
        self.store = store
    }

    var isRecording: Bool { stream != nil }

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

    func start(candidate: MeetingCandidate) async throws {
        guard stream == nil else { throw RecordingError.alreadyRecording }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecordingError.microphonePermissionDenied
        }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw RecordingError.screenPermissionDenied
        }

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

        let configuration = SCStreamConfiguration()
        configuration.width = 16
        configuration.height = 16
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        configuration.queueDepth = 2
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.showsCursor = false

        try store.prepareDirectories()
        let workDirectory = store.recordingsURL.appending(
            path: ".capture-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let captureOutput = SegmentedAudioCapture(workDirectory: workDirectory) { [weak self] error in
            Task { @MainActor in self?.captureDidFail(error) }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

        do {
            try stream.addStreamOutput(
                captureOutput,
                type: .audio,
                sampleHandlerQueue: captureOutput.sampleQueue
            )
            try stream.addStreamOutput(
                captureOutput,
                type: .microphone,
                sampleHandlerQueue: captureOutput.sampleQueue
            )
        } catch {
            await captureOutput.cancel()
            throw error
        }

        self.workDirectory = workDirectory
        self.captureOutput = captureOutput
        self.stream = stream
        captureFailure = nil
        recoverableURL = nil
        isStopping = false
        hasStartedHealthyCapture = false

        do {
            Self.logger.info("Starting direct audio capture for \(candidate.appName, privacy: .public)")
            try await stream.startCapture()
            try await captureOutput.waitUntilReady(timeout: 10)
            hasStartedHealthyCapture = true
            startHealthMonitor(for: captureOutput)
            Self.logger.info("Microphone and system-audio sample flow verified")
        } catch {
            Self.logger.error("Capture startup failed: \(error.localizedDescription, privacy: .public)")
            await cancel()
            throw error
        }
    }

    func stop(expectedDuration: TimeInterval) async throws -> RecordingArtifacts {
        guard let stream, let captureOutput, let workDirectory else {
            throw RecordingError.couldNotCreateRecording
        }

        isStopping = true
        healthTask?.cancel()
        healthTask = nil
        let reportedCaptureFailure = captureFailure

        do {
            try await stream.stopCapture()
        } catch {
            Self.logger.error("SCStream stop failed; finalizing captured chunks: \(error.localizedDescription, privacy: .public)")
        }
        try? stream.removeStreamOutput(captureOutput, type: .audio)
        try? stream.removeStreamOutput(captureOutput, type: .microphone)

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
            throw RecordingError.exportFailed
        }

        let artifacts = RecordingArtifacts(
            combinedURL: audioURL,
            microphoneURL: await mixTrack(.microphone, from: result.segments, origin: origin),
            systemURL: await mixTrack(.system, from: result.segments, origin: origin)
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
    private func mixTrack(
        _ source: AudioSource,
        from segments: [AudioSegment],
        origin: CMTime
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
        Task { @MainActor [weak self] in self?.captureDidFail(error) }
    }

    private func startHealthMonitor(for captureOutput: SegmentedAudioCapture) {
        healthTask = Task { @MainActor [weak self, weak captureOutput] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self, let captureOutput else { return }
                if let error = captureOutput.healthIssue(maximumSilence: 8) {
                    self.captureDidFail(error)
                    return
                }
            }
        }
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
        healthTask?.cancel()
        healthTask = nil
        stream = nil
        captureOutput = nil
        workDirectory = nil
        captureFailure = nil
        isStopping = false
        hasStartedHealthyCapture = false
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

    private static func mixAudioSegments(
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
            throw RecordingError.exportFailed
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try await exporter.export(to: destinationURL, as: .m4a)
    }

    private static func duration(of url: URL) async throws -> TimeInterval {
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        guard seconds.isFinite else { throw RecordingError.exportFailed }
        return seconds
    }
}

private enum AudioSource: String, Sendable {
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

    func waitUntilReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (failure, ready) = statusLock.withLock {
                (storedFailure, receivedSources == Set([.system, .microphone]))
            }

            if let failure { throw failure }
            if ready { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RecordingError.noAudioCaptured
    }

    func healthIssue(maximumSilence: TimeInterval) -> (any Error)? {
        statusLock.withLock {
            if let storedFailure { return storedFailure }

            let now = Date()
            for source in [AudioSource.system, .microphone] {
                guard let lastSampleDate = lastSampleDates[source],
                      now.timeIntervalSince(lastSampleDate) <= maximumSilence
                else {
                    return AudioCaptureError.samplesStopped(source)
                }
            }
            return nil
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
           current.elapsed(at: presentationTime) >= segmentDuration {
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
    private let segment: AudioSegment
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

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

        let startTime = CMSampleBufferGetPresentationTimeStamp(firstSample)
        let url = directory.appending(
            path: String(format: "%@-%04d.m4a", source.rawValue, index)
        )
        let writer = try AVAssetWriter(url: url, fileType: .m4a)
        let channelCount = max(1, min(Int(streamDescription.mChannelsPerFrame), 2))
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: streamDescription.mSampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: 96_000,
        ]
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
    case writerBackpressure
    case sampleWriteFailed

    var errorDescription: String? {
        switch self {
        case let .samplesStopped(source):
            return "\(source.rawValue.capitalized) audio samples stopped arriving."
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
