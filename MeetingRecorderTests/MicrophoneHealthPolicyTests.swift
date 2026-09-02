import XCTest
@testable import MeetingRecorder

final class MicrophoneHealthPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func observe(
        available: Bool = true,
        stalled: Bool = false,
        writerFailed: Bool = false,
        hasReceivedSamples: Bool = true,
        at seconds: TimeInterval
    ) -> MicrophoneHealthPolicy.Observation {
        .init(
            available: available,
            stalled: stalled,
            writerFailed: writerFailed,
            hasReceivedSamples: hasReceivedSamples,
            now: start.addingTimeInterval(seconds)
        )
    }

    func testFirstStallRestartsAndAPersistentStallDegrades() {
        var policy = MicrophoneHealthPolicy()
        XCTAssertEqual(policy.evaluate(observe(stalled: true, at: 0)), .restart)
        XCTAssertEqual(policy.evaluate(observe(stalled: true, at: 2)), .degrade)
    }

    func testSecondDropoutAfterSustainedHealthGetsItsOwnRestart() {
        var policy = MicrophoneHealthPolicy(replenishAfter: 30)
        XCTAssertEqual(policy.evaluate(observe(stalled: true, at: 0)), .restart)
        XCTAssertEqual(policy.evaluate(observe(at: 2)), .none)
        XCTAssertEqual(policy.evaluate(observe(at: 20)), .none)
        XCTAssertEqual(policy.evaluate(observe(at: 40)), .none)
        XCTAssertEqual(policy.evaluate(observe(stalled: true, at: 300)), .restart)
    }

    func testBurstyMicrophoneCannotLoopRestarts() {
        var policy = MicrophoneHealthPolicy(replenishAfter: 30)
        XCTAssertEqual(policy.evaluate(observe(stalled: true, at: 0)), .restart)
        XCTAssertEqual(policy.evaluate(observe(at: 2)), .none)
        XCTAssertEqual(policy.evaluate(observe(stalled: true, at: 10)), .degrade)
    }

    func testHealthyWindowRestartsWhenInterrupted() {
        var policy = MicrophoneHealthPolicy(replenishAfter: 30)
        XCTAssertEqual(policy.evaluate(observe(stalled: true, at: 0)), .restart)
        XCTAssertEqual(policy.evaluate(observe(at: 2)), .none)
        XCTAssertEqual(policy.evaluate(observe(stalled: true, at: 20)), .degrade)
        // Degraded now; samples resume, then it must flow another full window.
        XCTAssertEqual(policy.evaluate(observe(available: false, at: 30)), .resume)
        XCTAssertEqual(policy.evaluate(observe(stalled: true, at: 40)), .restart)
    }

    func testUnwritableMicrophoneCountsAsBroken() {
        var policy = MicrophoneHealthPolicy()
        XCTAssertEqual(policy.evaluate(observe(writerFailed: true, at: 0)), .restart)
        XCTAssertEqual(policy.evaluate(observe(writerFailed: true, at: 2)), .degrade)
    }

    func testResumeWaitsForWritableSamples() {
        var policy = MicrophoneHealthPolicy()
        XCTAssertEqual(policy.evaluate(observe(writerFailed: true, at: 0)), .restart)
        XCTAssertEqual(policy.evaluate(observe(writerFailed: true, at: 2)), .degrade)
        XCTAssertEqual(policy.evaluate(observe(available: false, writerFailed: true, at: 4)), .none)
        XCTAssertEqual(policy.evaluate(observe(available: false, at: 6)), .resume)
    }

    func testMissingMicrophoneStaysQuietUntilSamplesArrive() {
        var policy = MicrophoneHealthPolicy()
        XCTAssertEqual(
            policy.evaluate(observe(available: false, stalled: true, hasReceivedSamples: false, at: 0)),
            .none
        )
        XCTAssertEqual(policy.evaluate(observe(available: false, at: 2)), .resume)
    }
}
