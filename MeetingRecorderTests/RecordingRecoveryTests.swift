import AVFoundation
import Foundation
import XCTest
@testable import MeetingRecorder

final class RecordingRecoveryTests: XCTestCase {
    private var root: URL!
    private var store: TranscriptStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appending(path: "MeetingRecorderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = TranscriptStore(rootURL: root)
        try? store.prepareDirectories()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Segment filenames

    func testParsesSegmentFilenames() {
        let microphone = RecordingRecovery.parseSegmentFilename("microphone-0000.m4a")
        XCTAssertEqual(microphone?.source, .microphone)
        XCTAssertEqual(microphone?.index, 0)

        let system = RecordingRecovery.parseSegmentFilename("system-0012.m4a")
        XCTAssertEqual(system?.source, .system)
        XCTAssertEqual(system?.index, 12)
    }

    func testRejectsForeignFilenames() {
        XCTAssertNil(RecordingRecovery.parseSegmentFilename("system-0000.wav"))
        XCTAssertNil(RecordingRecovery.parseSegmentFilename("speaker-0000.m4a"))
        XCTAssertNil(RecordingRecovery.parseSegmentFilename("system-.m4a"))
        XCTAssertNil(RecordingRecovery.parseSegmentFilename("system-a1.m4a"))
        XCTAssertNil(RecordingRecovery.parseSegmentFilename(".DS_Store"))
    }

    // MARK: - Orphan detection

    func testSweepFindsOnlyInactiveWorkDirectories() throws {
        let orphan = try makeWorkDirectory()
        let active = try makeWorkDirectory()
        try FileManager.default.createDirectory(
            at: store.recordingsURL.appending(path: "Not A Capture", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try Data().write(to: store.recordingsURL.appending(path: "2026-01-01-meeting.m4a"))
        // A stray file with the directory prefix must not be treated as one.
        try Data().write(to: store.recordingsURL.appending(path: ".capture-not-a-directory"))

        let found = RecordingRecovery.orphanedWorkDirectories(
            in: store.recordingsURL,
            excluding: active
        )
        XCTAssertEqual(found.map(\.lastPathComponent), [orphan.lastPathComponent])
    }

    func testSweepOfMissingRecordingsDirectoryIsEmpty() {
        let found = RecordingRecovery.orphanedWorkDirectories(
            in: root.appending(path: "nowhere", directoryHint: .isDirectory),
            excluding: nil
        )
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - Recovery

    func testRecoversSegmentsIntoCombinedAndTrackMixes() async throws {
        let workDirectory = try makeWorkDirectory()
        try writeAudioSegment(named: "system-0000.m4a", seconds: 2, in: workDirectory)
        try writeAudioSegment(named: "system-0001.m4a", seconds: 1, in: workDirectory)
        try writeAudioSegment(named: "microphone-0000.m4a", seconds: 2, in: workDirectory)

        let recovered = try await RecordingRecovery.recover(workDirectory: workDirectory, into: store)

        let artifacts = try XCTUnwrap(recovered).artifacts
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.combinedURL.path))
        XCTAssertNotNil(artifacts.microphoneURL)
        XCTAssertNotNil(artifacts.systemURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workDirectory.path),
            "The work directory must be cleaned up after a successful recovery"
        )

        // The system segments lie back to back, so the combined timeline runs
        // to roughly three seconds (AAC priming allows a small tolerance).
        let combined = try await AVURLAsset(url: artifacts.combinedURL).load(.duration).seconds
        XCTAssertEqual(combined, 3, accuracy: 0.3)
        let microphone = try await AVURLAsset(url: try XCTUnwrap(artifacts.microphoneURL)).load(.duration).seconds
        XCTAssertEqual(microphone, 2, accuracy: 0.3)
    }

    func testSkipsUnreadableSegmentsAndRecoversTheRest() async throws {
        let workDirectory = try makeWorkDirectory()
        // A crash leaves the in-flight segment unfinalized and unreadable.
        try Data("not audio".utf8).write(to: workDirectory.appending(path: "system-0000.m4a"))
        try writeAudioSegment(named: "microphone-0000.m4a", seconds: 1, in: workDirectory)

        let recovered = try await RecordingRecovery.recover(workDirectory: workDirectory, into: store)

        let artifacts = try XCTUnwrap(recovered).artifacts
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.combinedURL.path))
        XCTAssertNil(artifacts.microphoneURL, "A single-source recording has no per-source tracks")
        XCTAssertNil(artifacts.systemURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDirectory.path))
    }

    func testRemovesWorkDirectoryWhenNothingIsRecoverable() async throws {
        let workDirectory = try makeWorkDirectory()
        try Data("not audio".utf8).write(to: workDirectory.appending(path: "system-0000.m4a"))
        try Data("junk".utf8).write(to: workDirectory.appending(path: "notes.txt"))

        let recovered = try await RecordingRecovery.recover(workDirectory: workDirectory, into: store)

        XCTAssertNil(recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDirectory.path))
    }

    // MARK: - Helpers

    private func makeWorkDirectory() throws -> URL {
        let url = store.recordingsURL.appending(
            path: "\(RecordingRecovery.workDirectoryPrefix)\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeAudioSegment(named filename: String, seconds: Double, in directory: URL) throws {
        let url = directory.appending(path: filename)
        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw RecordingError.couldNotCreateRecording
        }
        buffer.frameLength = frames
        try file.write(from: buffer)
        file.close()
    }
}
