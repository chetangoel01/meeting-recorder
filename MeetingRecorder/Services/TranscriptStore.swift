import CryptoKit
import Foundation

struct MeetingNote: Sendable {
    var id: UUID
    var title: String
    var sourceApplication: String
    var startedAt: Date
    var duration: TimeInterval
    var cost: Double?
    var audioFilename: String?
    var analysisMarkdown: String?
    var transcriptMarkdown: String

    // Renders the canonical on-disk Markdown: YAML frontmatter (readable in
    // Obsidian) followed by analysis sections and the transcript.
    func rendered() -> String {
        var frontmatter = [
            "id: \(id.uuidString)",
            "title: \"\(title.replacingOccurrences(of: "\"", with: "'"))\"",
            "source: \"\(sourceApplication.replacingOccurrences(of: "\"", with: "'"))\"",
            "recorded: \(Self.isoString(from: startedAt))",
            "duration_seconds: \(Int(duration.rounded()))",
        ]
        if let cost {
            frontmatter.append(String(format: "openrouter_cost_usd: %.4f", cost))
        }
        if let audioFilename {
            frontmatter.append("audio: \"\(audioFilename)\"")
        }

        var body = "# \(title)\n"
        if let analysisMarkdown, !analysisMarkdown.isEmpty {
            body += "\n\(analysisMarkdown.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        body += "\n## Transcript\n\n\(transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines))\n"

        return "---\n\(frontmatter.joined(separator: "\n"))\n---\n\n\(body)"
    }

    static func parse(_ text: String, fileURL: URL, fallbackDate: Date) -> MeetingNote {
        var fields: [String: String] = [:]
        var body = text

        if text.hasPrefix("---\n"),
           let closeRange = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            let header = text[text.index(text.startIndex, offsetBy: 4)..<closeRange.lowerBound]
            body = String(text[closeRange.upperBound...])
            for line in header.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                fields[key] = value
            }
        }

        let title = fields["title"]
            ?? body.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
            ?? fileURL.deletingPathExtension().lastPathComponent

        let (analysis, transcript) = splitBody(body)

        return MeetingNote(
            id: fields["id"].flatMap(UUID.init(uuidString:)) ?? Self.stableID(for: fileURL),
            title: title,
            sourceApplication: fields["source"] ?? "Meeting",
            startedAt: fields["recorded"].flatMap(Self.isoDate(from:)) ?? fallbackDate,
            duration: fields["duration_seconds"].flatMap(TimeInterval.init) ?? 0,
            cost: fields["openrouter_cost_usd"].flatMap(Double.init),
            audioFilename: fields["audio"],
            analysisMarkdown: analysis,
            transcriptMarkdown: transcript
        )
    }

    // Old flat notes carry no frontmatter id; hash the filename into a stable
    // UUID so list selection survives reloads without rewriting user files.
    static func stableID(for fileURL: URL) -> UUID {
        let digest = SHA256.hash(data: Data(fileURL.lastPathComponent.utf8))
        let bytes = Array(digest.prefix(16))
        return NSUUID(uuidBytes: bytes) as UUID
    }

    private static func splitBody(_ body: String) -> (analysis: String?, transcript: String) {
        guard let transcriptRange = body.range(of: "## Transcript") else {
            return (nil, body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let transcript = body[transcriptRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var head = String(body[..<transcriptRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("# "), let newline = head.firstIndex(of: "\n") {
            head = String(head[head.index(after: newline)...])
        }
        // Old notes put "- Recorded:" metadata bullets here; they are covered
        // by frontmatter now, so only heading-led content counts as analysis.
        let analysis = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard analysis.hasPrefix("##") else { return (nil, transcript) }
        return (analysis, transcript)
    }

    static func isoString(from date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func isoDate(from string: String) -> Date? {
        try? Date(string, strategy: .iso8601)
    }
}

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

    func newRecordingURL(extension fileExtension: String, suffix: String = "meeting") throws -> URL {
        try prepareDirectories()
        return recordingsURL.appending(path: "\(Self.filenameTimestamp())-\(suffix).\(fileExtension)")
    }

    // MARK: - Folders

    func folders() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: transcriptsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func createFolder(_ name: String) throws -> String {
        let cleaned = Self.safeFolderName(name)
        guard !cleaned.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(
            at: transcriptsURL.appending(path: cleaned, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        return cleaned
    }

    func move(_ record: TranscriptRecord, toFolder folder: String?) throws -> URL {
        let destinationDirectory: URL
        if let folder {
            destinationDirectory = transcriptsURL.appending(path: Self.safeFolderName(folder), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } else {
            destinationDirectory = transcriptsURL
        }
        let destination = destinationDirectory.appending(path: record.markdownURL.lastPathComponent)
        guard destination != record.markdownURL else { return destination }
        try FileManager.default.moveItem(at: record.markdownURL, to: destination)
        return destination
    }

    func trash(_ record: TranscriptRecord) throws {
        try FileManager.default.trashItem(at: record.markdownURL, resultingItemURL: nil)
    }

    // MARK: - Notes

    func save(_ note: MeetingNote, folder: String?) throws -> TranscriptRecord {
        try prepareDirectories()

        let directory: URL
        var cleanedFolder: String?
        if let folder, !Self.safeFolderName(folder).isEmpty {
            cleanedFolder = Self.safeFolderName(folder)
            directory = transcriptsURL.appending(path: cleanedFolder!, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } else {
            directory = transcriptsURL
        }

        let markdownURL = directory.appending(
            path: "\(Self.filenameTimestamp(note.startedAt))-\(Self.safeFilename(note.title)).md"
        )
        try note.rendered().write(to: markdownURL, atomically: true, encoding: .utf8)
        return record(for: note, at: markdownURL, folder: cleanedFolder)
    }

    // Rewrites an existing note in place (used to add analysis after the
    // transcript is already safely on disk).
    func update(_ record: TranscriptRecord, with note: MeetingNote) throws -> TranscriptRecord {
        try note.rendered().write(to: record.markdownURL, atomically: true, encoding: .utf8)
        return self.record(for: note, at: record.markdownURL, folder: record.folder)
    }

    func exportCopy(of record: TranscriptRecord, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: record.markdownURL.lastPathComponent)
        let contents = try String(contentsOf: record.markdownURL, encoding: .utf8)
        try contents.write(to: destination, atomically: true, encoding: .utf8)
    }

    func loadTranscripts() -> [TranscriptRecord] {
        var results: [TranscriptRecord] = []
        results.append(contentsOf: loadNotes(in: transcriptsURL, folder: nil))
        for folder in folders() {
            let folderURL = transcriptsURL.appending(path: folder, directoryHint: .isDirectory)
            results.append(contentsOf: loadNotes(in: folderURL, folder: folder))
        }
        return results.sorted { $0.startedAt > $1.startedAt }
    }

    private func loadNotes(in directory: URL, folder: String?) -> [TranscriptRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> TranscriptRecord? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let note = MeetingNote.parse(
                    text,
                    fileURL: url,
                    fallbackDate: values?.contentModificationDate ?? .distantPast
                )
                return record(for: note, at: url, folder: folder)
            }
    }

    private func record(for note: MeetingNote, at url: URL, folder: String?) -> TranscriptRecord {
        TranscriptRecord(
            id: note.id,
            title: note.title,
            sourceApplication: note.sourceApplication,
            startedAt: note.startedAt,
            duration: note.duration,
            text: note.transcriptMarkdown,
            analysis: note.analysisMarkdown,
            cost: note.cost,
            markdownURL: url,
            audioURL: note.audioFilename.map { recordingsURL.appending(path: $0) },
            folder: folder
        )
    }

    static func safeFolderName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
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
}
