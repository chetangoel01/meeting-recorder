import EventKit
import Foundation

@MainActor
final class CalendarMeetingMonitor {
    typealias Handler = @MainActor (MeetingCandidate) -> Void

    private let eventStore = EKEventStore()
    private let handler: Handler
    private var timer: Timer?
    private var promptedEventIdentifiers: Set<String> = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestAccessAndStart() async -> Bool {
        do {
            let granted: Bool
            switch authorizationStatus {
            case .fullAccess:
                granted = true
            case .notDetermined, .writeOnly:
                granted = try await eventStore.requestFullAccessToEvents()
            default:
                granted = false
            }
            if granted { start() }
            return granted
        } catch {
            return false
        }
    }

    func start() {
        guard timer == nil, authorizationStatus == .fullAccess else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll(now: Date = .now) {
        let start = now.addingTimeInterval(-5 * 60)
        let end = now.addingTimeInterval(15 * 60)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)

        for event in events {
            guard !event.isAllDay,
                  event.status != .canceled,
                  event.startDate.timeIntervalSince(now) <= 2 * 60,
                  event.endDate > now,
                  let provider = Self.providerName(for: event)
            else {
                continue
            }

            let eventID = event.eventIdentifier ?? "\(event.title ?? provider):\(event.startDate.timeIntervalSince1970)"
            guard promptedEventIdentifiers.insert(eventID).inserted else { continue }

            handler(
                MeetingCandidate(
                    id: "calendar:\(eventID)",
                    appName: event.title?.isEmpty == false ? event.title! : provider,
                    bundleIdentifier: nil,
                    processIdentifier: nil,
                    trigger: .calendar
                )
            )
        }

        let liveIDs = Set(events.compactMap(\.eventIdentifier))
        promptedEventIdentifiers = promptedEventIdentifiers.filter { liveIDs.contains($0) }
    }

    static func providerName(for event: EKEvent) -> String? {
        let fields = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if fields.contains("meet.google.com") { return "Google Meet" }
        if fields.contains("zoom.us") { return "Zoom" }
        if fields.contains("teams.microsoft.com") || fields.contains("teams.live.com") {
            return "Microsoft Teams"
        }
        if fields.contains("webex.com") { return "Webex" }
        if fields.contains("facetime") { return "FaceTime" }
        return nil
    }
}
