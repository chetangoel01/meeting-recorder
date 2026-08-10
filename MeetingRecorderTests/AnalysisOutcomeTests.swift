import XCTest
@testable import MeetingRecorder

final class AnalysisOutcomeTests: XCTestCase {
    func testParsesTitleFolderAndSections() {
        let outcome = AnalysisOutcome.parse(
            """
            Title: Ladle backend sync
            Folder: Work

            ## Summary
            Discussed the VPS deployment.

            ## Action items
            - [ ] Ship it — Chetan
            """,
            existingFolders: ["Work", "Interviews"]
        )

        XCTAssertEqual(outcome.title, "Ladle backend sync")
        XCTAssertEqual(outcome.suggestedFolder, "Work")
        XCTAssertTrue(outcome.analysisMarkdown.hasPrefix("## Summary"))
        XCTAssertTrue(outcome.analysisMarkdown.contains("- [ ] Ship it — Chetan"))
    }

    func testFolderMatchingIsCaseInsensitiveAgainstExistingFolders() {
        let outcome = AnalysisOutcome.parse(
            "Title: Sync\nFolder: work\n\n## Summary\nText.",
            existingFolders: ["Work"]
        )
        XCTAssertEqual(outcome.suggestedFolder, "Work")
    }

    func testFolderNoneAndMissingLinesAreTolerated() {
        let outcome = AnalysisOutcome.parse(
            "Folder: none\n\n## Summary\nJust a summary.",
            existingFolders: []
        )
        XCTAssertNil(outcome.title)
        XCTAssertNil(outcome.suggestedFolder)
        XCTAssertEqual(outcome.analysisMarkdown, "## Summary\nJust a summary.")

        let bare = AnalysisOutcome.parse("## Summary\nNo routing lines at all.", existingFolders: [])
        XCTAssertNil(bare.title)
        XCTAssertNil(bare.suggestedFolder)
        XCTAssertEqual(bare.analysisMarkdown, "## Summary\nNo routing lines at all.")
    }

    func testNewFolderNamesAreSanitized() {
        let outcome = AnalysisOutcome.parse(
            "Folder: Client/Acme\n\n## Summary\nText.",
            existingFolders: []
        )
        XCTAssertEqual(outcome.suggestedFolder, "Client-Acme")
    }
}
