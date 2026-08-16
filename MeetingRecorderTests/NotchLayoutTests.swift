import XCTest
@testable import MeetingRecorder

final class NotchLayoutTests: XCTestCase {
    func testPromptExpandsSidewaysWithoutDroppingFarBelowNotch() {
        let candidate = MeetingCandidate(
            id: "browser:arc",
            appName: "Arc",
            bundleIdentifier: nil,
            processIdentifier: nil,
            trigger: .browser
        )
        let size = NotchLayout.size(
            for: .prompt(candidate),
            collapsed: false,
            notchWidth: 204,
            notchHeight: 32
        )

        XCTAssertEqual(size.width, 560)
        XCTAssertEqual(size.height, 38)
    }

    func testCollapsedRecordingKeepsSafetyControlsBesideNotch() {
        let candidate = MeetingCandidate(
            id: "browser:arc",
            appName: "Arc",
            bundleIdentifier: nil,
            processIdentifier: nil,
            trigger: .browser
        )
        let session = RecordingSession(candidate: candidate, startedAt: .now)
        let size = NotchLayout.size(
            for: .recording(session),
            collapsed: true,
            notchWidth: 204,
            notchHeight: 32
        )

        XCTAssertEqual(size.width, 340)
        XCTAssertEqual(size.height, 38)
    }

    func testCollapsedStateLeavesOnlySmallGrabTargetBelowNotch() {
        let size = NotchLayout.size(
            for: .saving,
            collapsed: true,
            notchWidth: 204,
            notchHeight: 32
        )

        XCTAssertEqual(size.width, 248)
        XCTAssertEqual(size.height, 38)
    }
}
