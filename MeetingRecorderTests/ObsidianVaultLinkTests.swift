import Foundation
import XCTest
@testable import MeetingRecorder

final class ObsidianVaultLinkTests: XCTestCase {
    private var root: URL!
    private var vault: URL!
    private var transcripts: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appending(path: "ObsidianLinkTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        vault = root.appending(path: "Vault", directoryHint: .isDirectory)
        transcripts = root.appending(path: "Transcripts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testLinkCreatesWorkingSymlinkAndIsIdempotent() throws {
        _ = try ObsidianVaultLink.link(vaultRoot: vault, transcriptsURL: transcripts)
        XCTAssertTrue(ObsidianVaultLink.isLinked(vaultRoot: vault, transcriptsURL: transcripts))

        _ = try ObsidianVaultLink.link(vaultRoot: vault, transcriptsURL: transcripts)

        try "hello".write(
            to: transcripts.appending(path: "note.md"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            try String(contentsOf: vault.appending(path: "Meetings/note.md"), encoding: .utf8),
            "hello",
            "The vault's Meetings entry must show the store's live files"
        )
    }

    func testExistingFolderIsMovedAsideNotDeleted() throws {
        let old = vault.appending(path: "Meetings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try "old copy".write(to: old.appending(path: "copy.md"), atomically: true, encoding: .utf8)

        _ = try ObsidianVaultLink.link(vaultRoot: vault, transcriptsURL: transcripts)

        XCTAssertTrue(ObsidianVaultLink.isLinked(vaultRoot: vault, transcriptsURL: transcripts))
        XCTAssertEqual(
            try String(
                contentsOf: vault.appending(path: "Meetings (old exports)/copy.md"),
                encoding: .utf8
            ),
            "old copy",
            "Old exported copies must be moved aside, never deleted"
        )
    }

    func testUnlinkRemovesOnlyTheLink() throws {
        _ = try ObsidianVaultLink.link(vaultRoot: vault, transcriptsURL: transcripts)
        try "keep".write(to: transcripts.appending(path: "note.md"), atomically: true, encoding: .utf8)

        try ObsidianVaultLink.unlink(vaultRoot: vault, transcriptsURL: transcripts)

        XCTAssertFalse(ObsidianVaultLink.isLinked(vaultRoot: vault, transcriptsURL: transcripts))
        XCTAssertEqual(
            try String(contentsOf: transcripts.appending(path: "note.md"), encoding: .utf8),
            "keep",
            "Unlinking must never touch the store"
        )
    }

    func testUnlinkRefusesForeignDirectory() throws {
        // A real folder named Meetings (not our link) must survive an unlink call.
        let foreign = vault.appending(path: "Meetings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)

        try ObsidianVaultLink.unlink(vaultRoot: vault, transcriptsURL: transcripts)

        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    func testOpenURLEncodesVaultAndFolderPath() {
        let record = TranscriptRecord(
            id: UUID(),
            title: "Design review",
            sourceApplication: "Zoom",
            startedAt: Date(),
            duration: 60,
            text: "",
            analysis: nil,
            cost: nil,
            attendees: [],
            markdownURL: URL(filePath: "/store/Transcripts/Work Stuff/2026-08-15-design-review.md"),
            audioURL: nil,
            folder: "Work Stuff"
        )

        let url = ObsidianVaultLink.openURL(for: record, vaultRoot: URL(filePath: "/Users/x/My Vault"))

        XCTAssertEqual(url?.scheme, "obsidian")
        XCTAssertEqual(url?.host, "open")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "vault" }?.value, "My Vault")
        XCTAssertEqual(
            items?.first { $0.name == "file" }?.value,
            "Meetings/Work Stuff/2026-08-15-design-review"
        )
    }
}
