import XCTest
@testable import MeetingRecorder

final class TrackTranscriptBuilderTests: XCTestCase {
    func testInterleavesSpeakersByChunkStartTime() {
        let markdown = TrackTranscriptBuilder.markdown(
            me: [
                TimedTranscriptChunk(offset: 120, text: "Sounds good, I will take that."),
            ],
            them: [
                TimedTranscriptChunk(offset: 0, text: "Welcome everyone."),
                TimedTranscriptChunk(offset: 240, text: "Next topic."),
            ]
        )

        XCTAssertEqual(
            markdown,
            """
            **Them** [0:00]
            Welcome everyone.

            **Me** [2:00]
            Sounds good, I will take that.

            **Them** [4:00]
            Next topic.
            """
        )
    }

    func testMergesConsecutiveSameSpeakerChunks() {
        let markdown = TrackTranscriptBuilder.markdown(
            me: [],
            them: [
                TimedTranscriptChunk(offset: 0, text: "Part one."),
                TimedTranscriptChunk(offset: 120, text: "Part two."),
            ]
        )

        XCTAssertEqual(
            markdown,
            """
            **Them** [0:00]
            Part one.

            Part two.
            """
        )
    }

    func testEqualOffsetsPutThemBeforeMe() {
        let markdown = TrackTranscriptBuilder.markdown(
            me: [TimedTranscriptChunk(offset: 0, text: "Reply.")],
            them: [TimedTranscriptChunk(offset: 0, text: "Question?")]
        )

        XCTAssertTrue(markdown.hasPrefix("**Them** [0:00]"))
        XCTAssertTrue(markdown.contains("**Me** [0:00]"))
    }

    func testTimestampFormatting() {
        XCTAssertEqual(TrackTranscriptBuilder.timestamp(0), "0:00")
        XCTAssertEqual(TrackTranscriptBuilder.timestamp(65), "1:05")
        XCTAssertEqual(TrackTranscriptBuilder.timestamp(3_725), "1:02:05")
    }
}
