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
        XCTAssertEqual(
            MeetingAppClassifier.nativeIdentity(bundleIdentifier: "us.zoom.xos.CptHost"),
            .init(bundleIdentifier: "us.zoom.xos", name: "Zoom")
        )
        XCTAssertEqual(
            MeetingAppClassifier.nativeIdentity(bundleIdentifier: "com.microsoft.teams2.helper"),
            .init(bundleIdentifier: "com.microsoft.teams2", name: "Microsoft Teams")
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
        XCTAssertEqual(
            MeetingAppClassifier.browserIdentity(
                bundleIdentifier: "company.thebrowser.Browser.helper.renderer",
                bundleURL: nil
            ),
            .init(bundleIdentifier: "company.thebrowser.Browser", name: "Arc")
        )
        XCTAssertEqual(
            MeetingAppClassifier.browserIdentity(
                bundleIdentifier: "com.google.Chrome.canary.helper.renderer",
                bundleURL: nil
            ),
            .init(bundleIdentifier: "com.google.Chrome.canary", name: "Chrome Canary")
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
