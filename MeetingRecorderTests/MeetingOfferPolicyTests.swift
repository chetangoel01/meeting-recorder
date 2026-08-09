import XCTest
@testable import MeetingRecorder

final class MeetingOfferPolicyTests: XCTestCase {
    private let browserMeeting = MeetingCandidate(
        id: "browser:arc",
        appName: "Arc",
        bundleIdentifier: "company.thebrowser.Browser",
        processIdentifier: nil,
        trigger: .browser
    )

    func testSameBrowserCanPromptAgainAfterPriorMeetingFailure() {
        let oldSession = RecordingSession(candidate: browserMeeting, startedAt: .now)

        XCTAssertEqual(
            RecorderPhase.failed(message: "Old failure", audioURL: nil).offerAction(
                for: browserMeeting,
                currentSession: oldSession
            ),
            .present
        )
    }

    func testCurrentMeetingIsNotOfferedTwice() {
        let session = RecordingSession(candidate: browserMeeting, startedAt: .now)

        XCTAssertEqual(
            RecorderPhase.recording(session).offerAction(
                for: browserMeeting,
                currentSession: session
            ),
            .ignore
        )
    }

    func testDifferentMeetingIsQueuedWhileBusy() {
        let existingSession = RecordingSession(candidate: .manual, startedAt: .now)

        XCTAssertEqual(
            RecorderPhase.transcribing(progress: 0.5).offerAction(
                for: browserMeeting,
                currentSession: existingSession
            ),
            .queue
        )
    }

    func testCalendarBackupDoesNotQueueDuplicateAudioPrompt() {
        let calendarMeeting = MeetingCandidate(
            id: "calendar:weekly-sync",
            appName: "Weekly sync",
            bundleIdentifier: nil,
            processIdentifier: nil,
            trigger: .calendar
        )
        let calendarSession = RecordingSession(candidate: calendarMeeting, startedAt: .now)

        XCTAssertEqual(
            RecorderPhase.recording(calendarSession).offerAction(
                for: browserMeeting,
                currentSession: calendarSession
            ),
            .ignore
        )
        XCTAssertEqual(
            RecorderPhase.prompt(browserMeeting).offerAction(
                for: calendarMeeting,
                currentSession: nil
            ),
            .ignore
        )
    }
}
