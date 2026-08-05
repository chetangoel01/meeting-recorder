import Foundation

struct MeetingCandidate: Identifiable, Equatable, Sendable {
    enum Trigger: String, Sendable {
        case nativeApp
        case browser
        case calendar
        case manual
    }

    let id: String
    let appName: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t?
    let trigger: Trigger

    static let manual = MeetingCandidate(
        id: "manual",
        appName: "Manual recording",
        bundleIdentifier: nil,
        processIdentifier: nil,
        trigger: .manual
    )
}

struct RecordingSession: Equatable, Sendable {
    let candidate: MeetingCandidate
    let startedAt: Date
}

struct TranscriptRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let sourceApplication: String
    let startedAt: Date
    let duration: TimeInterval
    let text: String
    let cost: Double?
    let markdownURL: URL
    let audioURL: URL?
}

enum RecorderPhase: Equatable, Sendable {
    case idle
    case prompt(MeetingCandidate)
    case preparing(MeetingCandidate)
    case recording(RecordingSession)
    case saving
    case transcribing(progress: Double)
    case completed(TranscriptRecord)
    case failed(message: String, audioURL: URL?)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}
