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
    var transcriptFilename: String?
    var attendees: [String] = []

    // The note file carries frontmatter, the title, and the analysis; the
    // transcript lives in a sibling file referenced by `transcript:` so notes
    // stay readable (in the app and in Obsidian) without a wall of dialogue.
    func renderedNote() -> String {
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
        if !attendees.isEmpty {
            let joined = attendees
                .map { $0.replacingOccurrences(of: "\"", with: "'") }
                .joined(separator: ", ")
            frontmatter.append("attendees: \"\(joined)\"")
        }
        if let audioFilename {
            frontmatter.append("audio: \"\(audioFilename)\"")
        }
        if let transcriptFilename {
            frontmatter.append("transcript: \"\(transcriptFilename)\"")
        }

        var body = "# \(title)\n"
        if let analysisMarkdown, !analysisMarkdown.isEmpty {
            body += "\n\(analysisMarkdown.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        if let transcriptFilename {
            body += "\n[Transcript](\(transcriptFilename))\n"
        } else {
            body += "\n## Transcript\n\n\(transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }

        return "---\n\(frontmatter.joined(separator: "\n"))\n---\n\n\(body)"
    }

    func renderedTranscript() -> String {
        transcriptMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
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

        let (analysis, inlineTranscript) = splitBody(body, hasTranscriptSibling: fields["transcript"] != nil)

        return MeetingNote(
            id: fields["id"].flatMap(UUID.init(uuidString:)) ?? Self.stableID(for: fileURL),
            title: title,
            sourceApplication: fields["source"] ?? "Meeting",
            startedAt: fields["recorded"].flatMap(Self.isoDate(from:)) ?? fallbackDate,
            duration: fields["duration_seconds"].flatMap(TimeInterval.init) ?? 0,
            cost: fields["openrouter_cost_usd"].flatMap(Double.init),
            audioFilename: fields["audio"],
            analysisMarkdown: analysis,
            transcriptMarkdown: inlineTranscript,
            transcriptFilename: fields["transcript"],
            attendees: fields["attendees"]
                .map { $0.components(separatedBy: ", ").filter { !$0.isEmpty } } ?? []
        )
    }

    // Old flat notes carry no frontmatter id; hash the filename into a stable
    // UUID so list selection survives reloads without rewriting user files.
    static func stableID(for fileURL: URL) -> UUID {
        let digest = SHA256.hash(data: Data(fileURL.lastPathComponent.utf8))
        let bytes = Array(digest.prefix(16))
        return NSUUID(uuidBytes: bytes) as UUID
    }

    private static func splitBody(_ body: String, hasTranscriptSibling: Bool) -> (analysis: String?, transcript: String) {
        var transcript = ""
        var head = body
        if let transcriptRange = body.range(of: "## Transcript") {
            transcript = body[transcriptRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            head = String(body[..<transcriptRange.lowerBound])
        }

        head = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("# "), let newline = head.firstIndex(of: "\n") {
            head = String(head[head.index(after: newline)...])
        }
        if hasTranscriptSibling {
            // Drop the trailing "[Transcript](...)" navigation link; it is
            // rendering plumbing, not analysis content.
            head = head
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[Transcript](") }
                .joined(separator: "\n")
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
    static let transcriptSuffix = ".transcript.md"

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
        if let sibling = Self.existingTranscriptURL(forNoteAt: record.markdownURL) {
            try? FileManager.default.moveItem(
                at: sibling,
                to: destinationDirectory.appending(path: sibling.lastPathComponent)
            )
        }
        return destination
    }

    func renameFolder(_ name: String, to newName: String) throws -> String {
        let cleaned = Self.safeFolderName(newName)
        guard !cleaned.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let source = transcriptsURL.appending(path: name, directoryHint: .isDirectory)
        let destination = transcriptsURL.appending(path: cleaned, directoryHint: .isDirectory)
        guard cleaned != name else { return cleaned }
        // Case-only renames ("work" → "Work") are the same directory on APFS;
        // the exists check would wrongly refuse them, and moveItem handles them.
        let caseOnlyRename = cleaned.compare(name, options: .caseInsensitive) == .orderedSame
        guard caseOnlyRename || !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return cleaned
    }

    // Deleting a folder never deletes meetings: contents move up to Unfiled
    // first, and the directory is only removed once it is empty.
    func deleteFolder(_ name: String) throws {
        let source = transcriptsURL.appending(path: name, directoryHint: .isDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for item in contents {
            var destination = transcriptsURL.appending(path: item.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                // Insert the folder name before the (possibly compound)
                // extension so note/.transcript.md sibling pairs stay paired.
                let filename = item.lastPathComponent
                let suffix = filename.lowercased().hasSuffix(Self.transcriptSuffix)
                    ? Self.transcriptSuffix
                    : (item.pathExtension.isEmpty ? "" : ".\(item.pathExtension)")
                let base = String(filename.dropLast(suffix.count))
                destination = transcriptsURL.appending(path: "\(base)-\(Self.safeFolderName(name))\(suffix)")
            }
            try FileManager.default.moveItem(at: item, to: destination)
        }
        try FileManager.default.removeItem(at: source)
    }

    func trash(_ record: TranscriptRecord) throws {
        let sibling = Self.existingTranscriptURL(forNoteAt: record.markdownURL)
        try FileManager.default.trashItem(at: record.markdownURL, resultingItemURL: nil)
        if let sibling {
            try? FileManager.default.trashItem(at: sibling, resultingItemURL: nil)
        }
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

        let baseName = "\(Self.filenameTimestamp(note.startedAt))-\(Self.safeFilename(note.title))"
        var savedNote = note
        savedNote.transcriptFilename = baseName + Self.transcriptSuffix

        let markdownURL = directory.appending(path: "\(baseName).md")
        try savedNote.renderedTranscript().write(
            to: directory.appending(path: savedNote.transcriptFilename!),
            atomically: true,
            encoding: .utf8
        )
        try savedNote.renderedNote().write(to: markdownURL, atomically: true, encoding: .utf8)
        return record(for: savedNote, at: markdownURL, folder: cleanedFolder)
    }

    // Rewrites the note file in place (used to add analysis after the
    // transcript is already safely on disk). The transcript sibling is not
    // rewritten — except for legacy inline notes, which gain one here so the
    // upgrade to the two-file shape never drops a transcript.
    func update(_ record: TranscriptRecord, with note: MeetingNote) throws -> TranscriptRecord {
        var updatedNote = note
        let directory = record.markdownURL.deletingLastPathComponent()
        if updatedNote.transcriptFilename == nil {
            let filename = record.markdownURL.deletingPathExtension().lastPathComponent + Self.transcriptSuffix
            try updatedNote.renderedTranscript().write(
                to: directory.appending(path: filename),
                atomically: true,
                encoding: .utf8
            )
            updatedNote.transcriptFilename = filename
        }
        try updatedNote.renderedNote().write(to: record.markdownURL, atomically: true, encoding: .utf8)
        return self.record(for: updatedNote, at: record.markdownURL, folder: record.folder)
    }

    // Re-reads the note from disk (with its transcript sibling) so callers can
    // modify one field and rewrite without guessing at unrendered state.
    func note(for record: TranscriptRecord) -> MeetingNote? {
        guard let text = try? String(contentsOf: record.markdownURL, encoding: .utf8) else { return nil }
        var note = MeetingNote.parse(text, fileURL: record.markdownURL, fallbackDate: record.startedAt)
        if let transcriptFilename = note.transcriptFilename {
            let siblingURL = record.markdownURL.deletingLastPathComponent().appending(path: transcriptFilename)
            if let transcript = try? String(contentsOf: siblingURL, encoding: .utf8) {
                note.transcriptMarkdown = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return note
    }

    // Retitles the note in place. The filename keeps its original slug so the
    // audio link, transcript sibling, and any Obsidian copies stay valid.
    func rename(_ record: TranscriptRecord, to title: String) throws -> TranscriptRecord {
        guard var note = note(for: record) else { throw CocoaError(.fileReadCorruptFile) }
        note.title = title
        return try update(record, with: note)
    }

    func exportCopy(of record: TranscriptRecord, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = try String(contentsOf: record.markdownURL, encoding: .utf8)
        try contents.write(
            to: directory.appending(path: record.markdownURL.lastPathComponent),
            atomically: true,
            encoding: .utf8
        )
        if let sibling = Self.existingTranscriptURL(forNoteAt: record.markdownURL) {
            let transcriptContents = try String(contentsOf: sibling, encoding: .utf8)
            try transcriptContents.write(
                to: directory.appending(path: sibling.lastPathComponent),
                atomically: true,
                encoding: .utf8
            )
        }
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
            .filter {
                $0.pathExtension.lowercased() == "md"
                    && !$0.lastPathComponent.lowercased().hasSuffix(Self.transcriptSuffix)
            }
            .compactMap { url -> TranscriptRecord? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                var note = MeetingNote.parse(
                    text,
                    fileURL: url,
                    fallbackDate: values?.contentModificationDate ?? .distantPast
                )
                if let transcriptFilename = note.transcriptFilename {
                    let siblingURL = directory.appending(path: transcriptFilename)
                    if let transcript = try? String(contentsOf: siblingURL, encoding: .utf8) {
                        note.transcriptMarkdown = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
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
            attendees: note.attendees,
            markdownURL: url,
            audioURL: note.audioFilename.map { recordingsURL.appending(path: $0) },
            folder: folder
        )
    }

    private static func existingTranscriptURL(forNoteAt noteURL: URL) -> URL? {
        let candidate = noteURL.deletingPathExtension().appendingPathExtension("transcript.md")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
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
