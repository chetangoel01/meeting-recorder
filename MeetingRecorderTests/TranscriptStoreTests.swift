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
            transcriptMarkdown: "**Me** [0:00]\nWe agreed to ship the smaller version.",
            transcriptFilename: nil
        )
    }

    func testSavesNoteAndTranscriptAsSiblingFiles() throws {
        let note = makeNote(analysis: "## Summary\n\nShipped the smaller version.")
        let saved = try store.save(note, folder: nil)

        let noteText = try String(contentsOf: saved.markdownURL, encoding: .utf8)
        XCTAssertFalse(
            noteText.contains("We agreed to ship"),
            "The transcript body must not live in the note file"
        )
        XCTAssertTrue(noteText.contains("transcript: \""))

        let siblingURL = saved.markdownURL.deletingPathExtension()
            .appendingPathExtension("transcript.md")
        XCTAssertEqual(
            try String(contentsOf: siblingURL, encoding: .utf8),
            "**Me** [0:00]\nWe agreed to ship the smaller version.\n"
        )
    }

    func testTranscriptSiblingsAreNotDoubleCountedAsNotes() throws {
        _ = try store.save(makeNote(analysis: "## Summary\n\nOne meeting."), folder: nil)

        let loaded = store.loadTranscripts()
        XCTAssertEqual(loaded.count, 1, "The .transcript.md sibling must not appear as its own note")
        XCTAssertEqual(loaded.first?.text, "**Me** [0:00]\nWe agreed to ship the smaller version.")
        XCTAssertEqual(loaded.first?.analysis, "## Summary\n\nOne meeting.")
    }

    func testNoteRoundTripsThroughFrontmatter() throws {
        let note = makeNote(analysis: "## Summary\n\nShipped it.\n\n## Action items\n- [ ] Update the spec — Me")
        _ = try store.save(note, folder: nil)

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
            "## Summary\n\nShipped it.\n\n## Action items\n- [ ] Update the spec — Me"
        )
        XCTAssertNil(loaded.first?.folder)
    }

    func testParsesLegacyNoteWithInlineTranscript() throws {
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

    func testUpdatingLegacyNoteCreatesTranscriptSibling() throws {
        try store.prepareDirectories()
        let legacy = "# Standup\n\n## Transcript\n\nOld style transcript body."
        let url = store.transcriptsURL.appending(path: "2026-08-09-130000-standup.md")
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        guard let record = store.loadTranscripts().first else {
            return XCTFail("Legacy note did not load")
        }
        var note = MeetingNote.parse(legacy, fileURL: url, fallbackDate: .now)
        note.analysisMarkdown = "## Summary\n\nAdded later."
        _ = try store.update(record, with: note)

        let reloaded = store.loadTranscripts()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.analysis, "## Summary\n\nAdded later.")
        XCTAssertEqual(
            reloaded.first?.text,
            "Old style transcript body.",
            "Upgrading a legacy note must not drop its transcript"
        )
        let sibling = url.deletingPathExtension().appendingPathExtension("transcript.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testMovingANoteCarriesItsTranscript() throws {
        let saved = try store.save(makeNote(), folder: nil)
        _ = try store.createFolder("Interviews")

        _ = try store.move(saved, toFolder: "Interviews")
        let loaded = store.loadTranscripts()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.folder, "Interviews")
        XCTAssertEqual(loaded.first?.id, saved.id, "Frontmatter id survives a move")
        XCTAssertEqual(
            loaded.first?.text,
            "**Me** [0:00]\nWe agreed to ship the smaller version.",
            "The transcript sibling must move with its note"
        )
    }

    func testExportCopyIncludesTranscriptSibling() throws {
        let saved = try store.save(makeNote(analysis: "## Summary\n\nExported."), folder: nil)
        let exportDirectory = root.appending(path: "vault-export", directoryHint: .isDirectory)

        try store.exportCopy(of: saved, to: exportDirectory)

        let exportedNote = exportDirectory.appending(path: saved.markdownURL.lastPathComponent)
        let exportedTranscript = exportDirectory.appending(
            path: saved.markdownURL.deletingPathExtension().lastPathComponent + ".transcript.md"
        )
        XCTAssertEqual(
            try String(contentsOf: exportedNote, encoding: .utf8),
            try String(contentsOf: saved.markdownURL, encoding: .utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedTranscript.path))
    }
}
