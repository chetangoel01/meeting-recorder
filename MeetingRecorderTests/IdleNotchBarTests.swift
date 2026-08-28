import XCTest
@testable import MeetingRecorder

@MainActor
final class IdleNotchBarTests: XCTestCase {
    private let candidate = MeetingCandidate(
        id: "browser:arc",
        appName: "Arc",
        bundleIdentifier: nil,
        processIdentifier: nil,
        trigger: .browser
    )

    func testIdleBarIsOnForExistingInstalls() {
        let suite = "MeetingRecorderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(AppSettings(defaults: defaults).showsIdleNotchBar)
    }

    func testIdleBarChoiceRoundTripsThroughDefaults() {
        let suite = "MeetingRecorderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        AppSettings(defaults: defaults).showsIdleNotchBar = false
        XCTAssertFalse(AppSettings(defaults: defaults).showsIdleNotchBar)

        AppSettings(defaults: defaults).showsIdleNotchBar = true
        XCTAssertTrue(AppSettings(defaults: defaults).showsIdleNotchBar)
    }

    func testOnlyTheIdleBarIsSuppressed() {
        XCTAssertFalse(NotchLayout.isOnScreen(phase: .idle, showsIdleBar: false))
        XCTAssertTrue(NotchLayout.isOnScreen(phase: .idle, showsIdleBar: true))
    }

    // Turning the idle bar off must not cost a Mac without a notch the prompt,
    // the recording controls, or a failure it has to act on.
    func testActiveStatesStayOnScreenWithoutTheIdleBar() {
        let session = RecordingSession(candidate: candidate, startedAt: .now)
        let record = TranscriptRecord(
            id: UUID(),
            title: "Standup",
            sourceApplication: "Arc",
            startedAt: .now,
            duration: 600,
            text: "…",
            analysis: nil,
            cost: nil,
            attendees: [],
            markdownURL: URL(filePath: "/tmp/standup.md"),
            audioURL: nil,
            folder: nil
        )
        let active: [RecorderPhase] = [
            .prompt(candidate),
            .preparing(candidate),
            .recording(session),
            .saving,
            .transcribing(progress: 0.5),
            .analyzing,
            .completed(record),
            .failed(message: "Transcription failed.", audioURL: nil),
        ]

        for phase in active {
            XCTAssertTrue(
                NotchLayout.isOnScreen(phase: phase, showsIdleBar: false),
                "\(phase) must still show at the notch"
            )
        }
    }
}
