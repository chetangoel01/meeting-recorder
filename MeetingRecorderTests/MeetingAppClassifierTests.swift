import XCTest
@testable import MeetingRecorder

final class MeetingAppClassifierTests: XCTestCase {
    func testRecognizesSupportedNativeClients() {
        XCTAssertEqual(
            MeetingAppClassifier.nativeClientName(bundleIdentifier: "us.zoom.xos"),
            "Zoom"
        )
        XCTAssertEqual(
            MeetingAppClassifier.nativeClientName(bundleIdentifier: "com.microsoft.teams2"),
            "Microsoft Teams"
        )
        XCTAssertEqual(
            MeetingAppClassifier.nativeClientName(bundleIdentifier: "com.apple.FaceTime"),
            "FaceTime"
        )
    }

    func testRecognizesKnownBrowsersWithoutInspectingTheirBundle() {
        XCTAssertTrue(
            MeetingAppClassifier.isBrowser(
                bundleIdentifier: "company.thebrowser.Browser",
                bundleURL: nil
            )
        )
        XCTAssertTrue(
            MeetingAppClassifier.isBrowser(
                bundleIdentifier: "org.mozilla.firefox",
                bundleURL: nil
            )
        )
        XCTAssertTrue(
            MeetingAppClassifier.isBrowser(
                bundleIdentifier: "com.google.Chrome.helper.renderer",
                bundleURL: nil
            )
        )
        XCTAssertEqual(
            MeetingAppClassifier.browserName(bundleIdentifier: "company.thebrowser.Browser.helper"),
            "Arc"
        )
    }

    func testDoesNotTreatUnknownApplicationsAsBrowsers() {
        XCTAssertFalse(
            MeetingAppClassifier.isBrowser(
                bundleIdentifier: "com.example.Editor",
                bundleURL: nil
            )
        )
    }
}
