import XCTest
@testable import MeetingRecorder

final class MeetingActivityRuleTests: XCTestCase {
    func testBrowserMicrophoneAloneIsNotAMeeting() {
        XCTAssertFalse(
            MeetingActivityRule.isActive(
                trigger: .browser,
                runningInput: true,
                consecutiveOutputSamples: 0
            )
        )
    }

    func testBrowserRequiresSustainedTwoWayAudio() {
        XCTAssertFalse(
            MeetingActivityRule.isActive(
                trigger: .browser,
                runningInput: true,
                consecutiveOutputSamples: 1
            )
        )
        XCTAssertTrue(
            MeetingActivityRule.isActive(
                trigger: .browser,
                runningInput: true,
                consecutiveOutputSamples: 2
            )
        )
    }

    func testNativeMeetingClientStillPromptsFromEitherDirection() {
        XCTAssertTrue(
            MeetingActivityRule.isActive(
                trigger: .nativeApp,
                runningInput: true,
                consecutiveOutputSamples: 0
            )
        )
        XCTAssertTrue(
            MeetingActivityRule.isActive(
                trigger: .nativeApp,
                runningInput: false,
                consecutiveOutputSamples: 3
            )
        )
    }
}
