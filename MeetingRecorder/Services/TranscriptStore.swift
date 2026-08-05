import Foundation

struct TranscriptStore: Sendable {
    let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.rootURL = applicationSupport.appending(path: "Meeting Recorder", directoryHint: .isDirectory)
        }
    }

    var recordingsURL: URL {
        rootURL.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    var transcriptsURL: URL {
        rootURL.appending(path: "Transcripts", directoryHint: .isDirectory)
    }

    func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcriptsURL, withIntermediateDirectories: true)
    }

    func newRecordingURL(extension fileExtension: String) throws -> URL {
        try prepareDirectories()
        return recordingsURL.appending(path: "\(Self.filenameTimestamp())-meeting.\(fileExtension)")
    }

    func saveTranscript(
        title: String,
        sourceApplication: String,
        startedAt: Date,
        duration: TimeInterval,
        text: String,
        cost: Double?,
        audioURL: URL?
    ) throws -> TranscriptRecord {
        try prepareDirectories()

        let safeTitle = Self.safeFilename(title)
        let markdownURL = transcriptsURL.appending(
            path: "\(Self.filenameTimestamp(startedAt))-\(safeTitle).md"
        )
        let durationText = Self.durationFormatter.string(from: duration) ?? "Unknown"
        let costLine = cost.map { String(format: "- OpenRouter cost: $%.4f\n", $0) } ?? ""
        let audioLine = audioURL.map { "- Audio: \($0.lastPathComponent)\n" } ?? ""
        let markdown = """
        # \(title)

        - Recorded: \(Self.displayDateFormatter.string(from: startedAt))
        - Source: \(sourceApplication)
        - Duration: \(durationText)
        \(costLine)\(audioLine)
        ## Transcript

        \(text.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

        return TranscriptRecord(
            id: UUID(),
            title: title,
            sourceApplication: sourceApplication,
            startedAt: startedAt,
            duration: duration,
            text: text,
            cost: cost,
            markdownURL: markdownURL,
            audioURL: audioURL
        )
    }

    func loadTranscripts() -> [TranscriptRecord] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: transcriptsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> TranscriptRecord? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let date = values?.contentModificationDate ?? .distantPast
                let title = text.split(separator: "\n").first.map { String($0).replacingOccurrences(of: "# ", with: "") }
                    ?? url.deletingPathExtension().lastPathComponent
                let transcript = text.components(separatedBy: "## Transcript\n\n").last ?? text
                return TranscriptRecord(
                    id: UUID(),
                    title: title,
                    sourceApplication: "Saved transcript",
                    startedAt: date,
                    duration: 0,
                    text: transcript,
                    cost: nil,
                    markdownURL: url,
                    audioURL: nil
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "- "))
        let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(cleaned)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "--", with: "-")
            .lowercased()
    }

    private static func filenameTimestamp(_ date: Date = .now) -> String {
        filenameDateFormatter.string(from: date)
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
