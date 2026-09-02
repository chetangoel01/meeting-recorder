import AVFoundation
import XCTest
@testable import MeetingRecorder

// Runs the single-track path against a stubbed OpenRouter: a 5 s file cut
// into 2 s chunks makes three requests, so one chunk can be failed on its own.
final class TranscriptionClientTests: XCTestCase {
    private var audioURL: URL!

    override func setUpWithError() throws {
        audioURL = FileManager.default.temporaryDirectory
            .appending(path: "transcription-\(UUID().uuidString).m4a")
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
            ]
            let file = try AVAudioFile(forWriting: audioURL, settings: settings)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 5))
            buffer.frameLength = 16_000 * 5
            try file.write(from: buffer)
        }
        StubTranscriptionServer.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: audioURL)
    }

    private func makeClient() -> TranscriptionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTranscriptionServer.self]
        return TranscriptionClient(
            session: URLSession(configuration: configuration),
            singleTrackChunkDuration: 2,
            retryDelays: [0, 0, 0]
        )
    }

    private func transcribe() async throws -> TranscriptionResult {
        try await makeClient().transcribe(fileURL: audioURL, apiKey: "key", model: "m", progress: { _ in })
    }

    func testFailedChunkIsMarkedInPlaceAndTheRestKept() async throws {
        // Request order: chunk 0 ok; chunk 1 fails all three attempts; chunk 2 ok.
        StubTranscriptionServer.respond { index in
            (1...3).contains(index) ? .failure(503) : .success("words \(index)")
        }

        let result = try await transcribe()

        XCTAssertEqual(StubTranscriptionServer.requestCount, 5)
        XCTAssertTrue(result.text.contains("words 0"))
        XCTAssertTrue(result.text.contains("words 4"))
        XCTAssertTrue(result.text.contains("_[Transcription failed for 0:02–0:04: OpenRouter returned 503"), result.text)
        XCTAssertEqual(result.cost, 0.002)
    }

    func testNothingTranscribedFailsTheRun() async {
        StubTranscriptionServer.respond { _ in .failure(503) }

        do {
            _ = try await transcribe()
            XCTFail("expected the run to fail")
        } catch {
            XCTAssertEqual(StubTranscriptionServer.requestCount, 9)
            XCTAssertTrue(error.localizedDescription.contains("503"))
        }
    }

    func testAuthRejectionStopsAfterOneRequest() async {
        StubTranscriptionServer.respond { _ in .failure(401) }

        do {
            _ = try await transcribe()
            XCTFail("expected the run to fail")
        } catch {
            XCTAssertEqual(StubTranscriptionServer.requestCount, 1)
            XCTAssertTrue(error.localizedDescription.contains("401"))
        }
    }
}

private final class StubTranscriptionServer: URLProtocol {
    enum Reply {
        case success(String)
        case failure(Int)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var plan: @Sendable (Int) -> Reply = { _ in .failure(500) }

    static func reset() {
        lock.withLock {
            count = 0
            plan = { _ in .failure(500) }
        }
    }

    static func respond(_ plan: @escaping @Sendable (Int) -> Reply) {
        lock.withLock { self.plan = plan }
    }

    static var requestCount: Int { lock.withLock { count } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (index, plan) = Self.lock.withLock {
            let index = Self.count
            Self.count += 1
            return (index, Self.plan)
        }
        let status: Int
        let body: String
        switch plan(index) {
        case let .success(text):
            status = 200
            body = #"{"text": "\#(text)", "usage": {"cost": 0.001}}"#
        case let .failure(code):
            status = code
            body = #"{"error": {"message": "stubbed failure"}}"#
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
