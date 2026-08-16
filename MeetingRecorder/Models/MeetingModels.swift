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

enum ImportKind: Equatable {
    case transcript
    case audio

    static func classify(_ url: URL) -> ImportKind {
        let textExtensions: Set<String> = ["txt", "md", "markdown", "text"]
        return textExtensions.contains(url.pathExtension.lowercased()) ? .transcript : .audio
    }
}

struct TranscriptRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let sourceApplication: String
    let startedAt: Date
    let duration: TimeInterval
    let text: String
    let analysis: String?
    let cost: Double?
    let markdownURL: URL
    let audioURL: URL?
    let folder: String?
}

enum RecorderPhase: Equatable, Sendable {
    case idle
    case prompt(MeetingCandidate)
    case preparing(MeetingCandidate)
    case recording(RecordingSession)
    case saving
    case transcribing(progress: Double)
    case analyzing
    case completed(TranscriptRecord)
    case failed(message: String, audioURL: URL?)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

enum MeetingOfferAction: Equatable {
    case present
    case queue
    case ignore
}

extension RecorderPhase {
    func offerAction(
        for candidate: MeetingCandidate,
        currentSession: RecordingSession?
    ) -> MeetingOfferAction {
        switch self {
        case .idle, .completed, .failed:
            return .present
        case let .prompt(existing)
            where existing.trigger == .calendar || candidate.trigger == .calendar:
            return .ignore
        case let .preparing(existing)
            where existing.trigger == .calendar || candidate.trigger == .calendar:
            return .ignore
        case let .recording(session)
            where session.candidate.trigger == .calendar || candidate.trigger == .calendar:
            return .ignore
        case .saving
            where currentSession?.candidate.trigger == .calendar || candidate.trigger == .calendar:
            return .ignore
        case .transcribing
            where currentSession?.candidate.trigger == .calendar || candidate.trigger == .calendar:
            return .ignore
        case .analyzing
            where currentSession?.candidate.trigger == .calendar || candidate.trigger == .calendar:
            return .ignore
        case let .prompt(existing) where existing.id == candidate.id:
            return .ignore
        case let .preparing(existing) where existing.id == candidate.id:
            return .ignore
        case let .recording(session) where session.candidate.id == candidate.id:
            return .ignore
        case .saving where currentSession?.candidate.id == candidate.id:
            return .ignore
        case .transcribing where currentSession?.candidate.id == candidate.id:
            return .ignore
        case .analyzing where currentSession?.candidate.id == candidate.id:
            return .ignore
        default:
            return .queue
        }
    }
}
