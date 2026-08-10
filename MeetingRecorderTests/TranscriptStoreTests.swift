import Foundation
import XCTest
@testable import MeetingRecorder

final class TranscriptStoreTests: XCTestCase {
    private var root: URL!
    private var store: TranscriptStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appending(path: "MeetingRecorderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = TranscriptStore(rootURL: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeNote(analysis: String? = nil) -> MeetingNote {
        MeetingNote(
            id: UUID(),
            title: "Design review",
            sourceApplication: "Google Meet",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 95,
            cost: 0.01,
            audioFilename: nil,
            analysisMarkdown: analysis,
            transcriptMarkdown: "**Me** [0:00]\nWe agreed to ship the smaller version."
        )
    }

    func testNoteRoundTripsThroughFrontmatter() throws {
        let note = makeNote(analysis: "## Summary\n\nShipped the smaller version.\n\n## Action items\n- [ ] Update the spec — Me")
        let saved = try store.save(note, folder: nil)

        let loaded = store.loadTranscripts()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, note.id)
        XCTAssertEqual(loaded.first?.title, "Design review")
        XCTAssertEqual(loaded.first?.sourceApplication, "Google Meet")
        XCTAssertEqual(loaded.first?.startedAt, note.startedAt)
        XCTAssertEqual(loaded.first?.duration, 95)
        XCTAssertEqual(loaded.first?.text, note.transcriptMarkdown)
        XCTAssertEqual(
            loaded.first?.analysis,
            "## Summary\n\nShipped the smaller version.\n\n## Action items\n- [ ] Update the spec — Me"
        )
        XCTAssertNil(loaded.first?.folder)
        XCTAssertEqual(saved.markdownURL.deletingLastPathComponent(), store.transcriptsURL)
    }

    func testParsesLegacyNoteWithoutFrontmatter() throws {
        try store.prepareDirectories()
        let legacy = """
        # Standup

        - Recorded: August 9, 2026 at 1:00 PM
        - Source: Zoom

        ## Transcript

        Old style transcript body.
        """
        let url = store.transcriptsURL.appending(path: "2026-08-09-130000-standup.md")
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let loaded = store.loadTranscripts()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Standup")
        XCTAssertEqual(loaded.first?.text, "Old style transcript body.")
        XCTAssertNil(loaded.first?.analysis, "Metadata bullets must not be mistaken for analysis")
        XCTAssertEqual(loaded.first?.id, MeetingNote.stableID(for: url), "IDs must be stable across loads")
    }

    func testFoldersAndMoving() throws {
        let saved = try store.save(makeNote(), folder: nil)
        let folder = try store.createFolder("Interviews")
        XCTAssertEqual(folder, "Interviews")
        XCTAssertEqual(store.folders(), ["Interviews"])

        _ = try store.move(saved, toFolder: "Interviews")
        let loaded = store.loadTranscripts()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.folder, "Interviews")
        XCTAssertEqual(loaded.first?.id, saved.id, "Frontmatter id survives a move")
    }

    func testSavingDirectlyIntoFolderAndUpdating() throws {
        var note = makeNote()
        let saved = try store.save(note, folder: "Work")
        XCTAssertEqual(saved.folder, "Work")

        note.analysisMarkdown = "## Summary\n\nAdded later."
        let updated = try store.update(saved, with: note)
        XCTAssertEqual(updated.analysis, "## Summary\n\nAdded later.")
        XCTAssertEqual(store.loadTranscripts().first?.analysis, "## Summary\n\nAdded later.")
    }

    func testExportCopyWritesTheSameMarkdown() throws {
        let saved = try store.save(makeNote(), folder: nil)
        let exportDirectory = root.appending(path: "vault-export", directoryHint: .isDirectory)

        try store.exportCopy(of: saved, to: exportDirectory)

        let exported = exportDirectory.appending(path: saved.markdownURL.lastPathComponent)
        XCTAssertEqual(
            try String(contentsOf: exported, encoding: .utf8),
            try String(contentsOf: saved.markdownURL, encoding: .utf8)
        )
    }
}
