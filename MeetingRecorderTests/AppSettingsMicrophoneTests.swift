import XCTest
@testable import MeetingRecorder

@MainActor
final class AppSettingsMicrophoneTests: XCTestCase {
    func testMicrophoneSelectionRoundTripsThroughDefaults() {
        let suite = "MeetingRecorderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppSettings(defaults: defaults).microphoneID, "")
        AppSettings(defaults: defaults).microphoneID = "AppleUSBAudioEngine:C270"
        XCTAssertEqual(AppSettings(defaults: defaults).microphoneID, "AppleUSBAudioEngine:C270")
    }

    func testUnattachedMicrophoneFallsBackToDefault() {
        XCTAssertNil(ScreenAudioRecorder.resolveMicrophone(preferredID: ""))
        XCTAssertNil(ScreenAudioRecorder.resolveMicrophone(preferredID: "no-such-device"))
    }
}
