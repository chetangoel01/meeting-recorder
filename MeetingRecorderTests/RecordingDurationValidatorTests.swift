import XCTest
@testable import MeetingRecorder

final class RecordingDurationValidatorTests: XCTestCase {
    func testRejectsSilentEarlyCutoff() {
        XCTAssertFalse(
            RecordingDurationValidator.isComplete(
                expected: 26 * 60 + 12,
                actual: 5 * 60 + 3
            )
        )
    }

    func testAcceptsNormalFinalizationDifference() {
        XCTAssertTrue(
            RecordingDurationValidator.isComplete(expected: 30 * 60, actual: 29 * 60 + 55)
        )
    }

    func testShortRecordingsStillRequireAudio() {
        XCTAssertFalse(RecordingDurationValidator.isComplete(expected: 5, actual: 0))
        XCTAssertTrue(RecordingDurationValidator.isComplete(expected: 5, actual: 3))
    }
}
