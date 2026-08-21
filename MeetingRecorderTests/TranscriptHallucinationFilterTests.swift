import XCTest
@testable import MeetingRecorder

final class TranscriptHallucinationFilterTests: XCTestCase {
    func testDropsKnownFillerSegments() {
        let cleaned = TranscriptHallucinationFilter.clean(segments: [
            " Thank you.", " you", " Bye.", " [Music]", " شکریہ",
            " Okay, great. Photos are coming.", " Thanks for watching!",
        ])
        XCTAssertEqual(cleaned, ["Okay, great. Photos are coming."])
    }

    func testDropsSegmentsThatRepeatOneFillerPhrase() {
        XCTAssertTrue(TranscriptHallucinationFilter.isFiller("Thank you. Thank you. Thank you."))
        XCTAssertFalse(TranscriptHallucinationFilter.isFiller("Thank you for the update on the roadmap."))
    }

    func testCollapsesConsecutiveIdenticalSegments() {
        let cleaned = TranscriptHallucinationFilter.clean(segments: [
            "Next topic.", "Next topic.", "next topic", "Sounds good.", "Next topic.",
        ])
        XCTAssertEqual(cleaned, ["Next topic.", "Sounds good.", "Next topic."])
    }

    func testPlainTextFallbackSplitsOnWhisperDoubleSpaces() {
        let text = " Thank you.  Thank you.  No notes honestly, looks fine.  you  Good job."
        XCTAssertEqual(
            TranscriptHallucinationFilter.clean(text: text),
            "No notes honestly, looks fine. Good job."
        )
    }

    func testKeepsRealSpeech() {
        let cleaned = TranscriptHallucinationFilter.clean(segments: [
            "I agree with the onboarding.", "I think it's short and sweet.",
        ])
        XCTAssertEqual(cleaned.count, 2)
    }
}
