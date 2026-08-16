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

    func testSystemPromptKeepsRoutingContractOutsideCustomInstructions() {
        let custom = "Summarize in French, three paragraphs minimum."
        let prompt = AnalysisClient.systemPrompt(instructions: custom)

        XCTAssertTrue(prompt.hasPrefix(custom))
        XCTAssertTrue(prompt.contains("Title: <"), "Custom prompts must keep the Title routing line")
        XCTAssertTrue(prompt.contains("Folder: <"), "Custom prompts must keep the Folder routing line")

        let emptied = AnalysisClient.systemPrompt(instructions: "   \n")
        XCTAssertTrue(
            emptied.hasPrefix(AnalysisClient.defaultInstructions.prefix(40)),
            "A blank prompt falls back to the default instructions"
        )
    }

    func testImportKindClassifiesByExtension() {
        XCTAssertEqual(ImportKind.classify(URL(filePath: "/tmp/meeting.txt")), .transcript)
        XCTAssertEqual(ImportKind.classify(URL(filePath: "/tmp/meeting.MD")), .transcript)
        XCTAssertEqual(ImportKind.classify(URL(filePath: "/tmp/meeting.m4a")), .audio)
        XCTAssertEqual(ImportKind.classify(URL(filePath: "/tmp/meeting.mp3")), .audio)
        XCTAssertEqual(ImportKind.classify(URL(filePath: "/tmp/meeting")), .audio)
    }
}
