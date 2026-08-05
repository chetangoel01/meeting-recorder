import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

enum RecordingError: LocalizedError {
    case alreadyRecording
    case noDisplay
    case couldNotCreateRecording
    case microphonePermissionDenied
    case screenPermissionDenied
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
        case .exportFailed:
            return "The captured meeting could not be converted to an audio file."
        }
    }
}

@MainActor
final class ScreenAudioRecorder: NSObject, SCStreamDelegate {
    private let store: TranscriptStore
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputDelegate: RecordingOutputDelegate?
    private var rawURL: URL?
    private(set) var recoverableURL: URL?

    init(store: TranscriptStore) {
        self.store = store
    }

    var isRecording: Bool { stream != nil }

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

        let filter: SCContentFilter
        if let processIdentifier = candidate.processIdentifier,
           let application = content.applications.first(where: { $0.processID == processIdentifier }) {
            filter = SCContentFilter(
                display: display,
                including: [application],
                exceptingWindows: []
            )
        } else {
            let ownBundleID = Bundle.main.bundleIdentifier
            let excluded = content.applications.filter { $0.bundleIdentifier == ownBundleID }
            filter = SCContentFilter(
                display: display,
                excludingApplications: excluded,
                exceptingWindows: []
            )
        }

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

        let rawURL = try store.newRecordingURL(extension: "mp4")
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = rawURL
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264

        let delegate = RecordingOutputDelegate()
        let recordingOutput = SCRecordingOutput(
            configuration: recordingConfiguration,
            delegate: delegate
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addRecordingOutput(recordingOutput)

        self.rawURL = rawURL
        recoverableURL = rawURL
        self.stream = stream
        self.recordingOutput = recordingOutput
        self.outputDelegate = delegate

        do {
            try await stream.startCapture()
        } catch {
            clearState()
            try? FileManager.default.removeItem(at: rawURL)
            throw error
        }
    }

    func stop() async throws -> URL {
        guard let stream, let recordingOutput, let delegate = outputDelegate, let rawURL else {
            throw RecordingError.couldNotCreateRecording
        }

        try stream.removeRecordingOutput(recordingOutput)
        try await delegate.waitForFinish()
        try await stream.stopCapture()
        clearState()

        let audioURL = try store.newRecordingURL(extension: "m4a")
        do {
            try await Self.exportAudio(from: rawURL, to: audioURL)
            try? FileManager.default.removeItem(at: rawURL)
            recoverableURL = audioURL
            return audioURL
        } catch {
            throw RecordingError.exportFailed
        }
    }

    func cancel() async {
        if let stream { try? await stream.stopCapture() }
        if let rawURL { try? FileManager.default.removeItem(at: rawURL) }
        recoverableURL = nil
        clearState()
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor [weak self] in
            self?.outputDelegate?.finish(with: .failure(error))
        }
    }

    private func clearState() {
        stream = nil
        recordingOutput = nil
        outputDelegate = nil
        rawURL = nil
    }

    private static func captureDisplay(in content: SCShareableContent) -> SCDisplay? {
        let builtInScreen = NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("built-in") }
            ?? NSScreen.main
        let displayID = builtInScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return content.displays.first { $0.displayID == displayID } ?? content.displays.first
    }

    private static func exportAudio(from sourceURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty,
              let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else {
            throw RecordingError.exportFailed
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try await exporter.export(to: destinationURL, as: .m4a)
    }
}

private final class RecordingOutputDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var finishResult: Result<Void, any Error>?

    func waitForFinish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result = finishResult {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(with result: Result<Void, any Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            finishResult = result
            lock.unlock()
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finish(with: .success(()))
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        finish(with: .failure(error))
    }
}
