import EventKit
import XCTest
@testable import MeetingRecorder

@MainActor
final class CalendarMeetingMonitorTests: XCTestCase {
    func testFindsEachSupportedMeetingProvider() {
        let store = EKEventStore()

        let meet = EKEvent(eventStore: store)
        meet.url = URL(string: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(CalendarMeetingMonitor.providerName(for: meet), "Google Meet")

        let zoom = EKEvent(eventStore: store)
        zoom.notes = "Join https://example.zoom.us/j/123"
        XCTAssertEqual(CalendarMeetingMonitor.providerName(for: zoom), "Zoom")

        let teams = EKEvent(eventStore: store)
        teams.location = "https://teams.microsoft.com/l/meetup-join/example"
        XCTAssertEqual(CalendarMeetingMonitor.providerName(for: teams), "Microsoft Teams")

        let webex = EKEvent(eventStore: store)
        webex.url = URL(string: "https://company.webex.com/meet/person")
        XCTAssertEqual(CalendarMeetingMonitor.providerName(for: webex), "Webex")
    }

    func testIgnoresOrdinaryEvents() {
        let event = EKEvent(eventStore: EKEventStore())
        event.location = "Conference room A"
        XCTAssertNil(CalendarMeetingMonitor.providerName(for: event))
    }
}
