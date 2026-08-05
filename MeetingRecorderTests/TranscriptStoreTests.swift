import Foundation
import XCTest
@testable import MeetingRecorder

final class TranscriptStoreTests: XCTestCase {
    func testSavesReadableMarkdownAndLoadsItBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MeetingRecorderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TranscriptStore(rootURL: root)
        let saved = try store.saveTranscript(
            title: "Design review",
            sourceApplication: "Google Meet",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 95,
            text: "We agreed to ship the smaller version.",
            cost: 0.01,
            audioURL: nil
        )

        let markdown = try String(contentsOf: saved.markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Design review"))
        XCTAssertTrue(markdown.contains("Source: Google Meet"))
        XCTAssertTrue(markdown.contains("We agreed to ship the smaller version."))

        let loaded = store.loadTranscripts()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Design review")
        XCTAssertEqual(loaded.first?.text, "We agreed to ship the smaller version.")
    }
}
