import AppKit
import SwiftUI

private enum LibrarySelection: Hashable {
    case all
    case unfiled
    case folder(String)
}

struct TranscriptHistoryView: View {
    @ObservedObject var model: AppModel
    @State private var selection: LibrarySelection = .all
    @State private var selectedRecordID: UUID?
    @State private var searchText = ""
    @State private var newFolderPrompted = false
    @State private var newFolderName = ""
    @State private var recordAwaitingFolder: TranscriptRecord?

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            recordList
        } detail: {
            if let record = selectedRecord {
                NoteDetailView(model: model, record: record)
            } else {
                ContentUnavailableView(
                    "Select a meeting",
                    systemImage: "text.document",
                    description: Text("Choose a meeting from the list.")
                )
            }
        }
        .onAppear {
            model.reloadTranscripts()
            selectedRecordID = selectedRecordID ?? filteredRecords.first?.id
        }
        .alert("New folder", isPresented: $newFolderPrompted) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                newFolderName = ""
                guard !name.isEmpty, let created = model.createFolder(name) else { return }
                if let record = recordAwaitingFolder {
                    model.moveTranscript(record, toFolder: created)
                    recordAwaitingFolder = nil
                }
            }
            Button("Cancel", role: .cancel) {
                newFolderName = ""
                recordAwaitingFolder = nil
            }
        } message: {
            Text(recordAwaitingFolder == nil
                ? "Folders appear in the sidebar and as subfolders on disk."
                : "The meeting will move into the new folder.")
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All meetings", systemImage: "tray.full")
                    .badge(model.transcripts.count)
                    .tag(LibrarySelection.all)
                Label("Unfiled", systemImage: "tray")
                    .badge(model.transcripts.filter { $0.folder == nil }.count)
                    .tag(LibrarySelection.unfiled)
            }
            if !model.folders.isEmpty {
                Section("Folders") {
                    ForEach(model.folders, id: \.self) { folder in
                        Label(folder, systemImage: "folder")
                            .badge(model.transcripts.filter { $0.folder == folder }.count)
                            .tag(LibrarySelection.folder(folder))
                    }
                }
            }
        }
        .navigationTitle("Meetings")
        .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        .toolbar {
            Button("New folder", systemImage: "folder.badge.plus") {
                recordAwaitingFolder = nil
                newFolderPrompted = true
            }
            .help("New folder")
        }
    }

    private var recordList: some View {
        List(filteredRecords, selection: $selectedRecordID) { record in
            MeetingRow(record: record, showsFolder: selection == .all)
                .tag(record.id)
                .contextMenu { moveMenu(for: record) }
        }
        .listStyle(.inset)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search meetings")
        .toolbar {
            Button("Import meeting", systemImage: "square.and.arrow.down", action: model.presentImportPanel)
                .disabled(!model.phase.isIdle)
                .help("Import an audio recording or a transcript file")
        }
        .overlay {
            if filteredRecords.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No meetings here" : "No matches",
                    systemImage: searchText.isEmpty ? "waveform" : "magnifyingglass",
                    description: Text(
                        searchText.isEmpty
                            ? "Completed meeting notes will appear here."
                            : "No meeting titles or transcripts contain “\(searchText)”."
                    )
                )
            }
        }
    }

    @ViewBuilder
    private func moveMenu(for record: TranscriptRecord) -> some View {
        Menu("Move to") {
            Button("Unfiled") { model.moveTranscript(record, toFolder: nil) }
                .disabled(record.folder == nil)
            ForEach(model.folders, id: \.self) { folder in
                Button(folder) { model.moveTranscript(record, toFolder: folder) }
                    .disabled(record.folder == folder)
            }
            Divider()
            Button("New folder…") {
                recordAwaitingFolder = record
                newFolderPrompted = true
            }
        }
        Button("Copy transcript") { model.copyTranscript(record) }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([record.markdownURL])
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            if selectedRecordID == record.id { selectedRecordID = nil }
            model.deleteTranscript(record)
        }
    }

    private var filteredRecords: [TranscriptRecord] {
        var records = model.transcripts
        switch selection {
        case .all:
            break
        case .unfiled:
            records = records.filter { $0.folder == nil }
        case let .folder(folder):
            records = records.filter { $0.folder == folder }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.text.localizedCaseInsensitiveContains(query)
                || ($0.analysis?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var selectedRecord: TranscriptRecord? {
        model.transcripts.first { $0.id == selectedRecordID }
    }
}

// Mail-style row: title with the date right-aligned, then a quiet second line.
private struct MeetingRow: View {
    let record: TranscriptRecord
    let showsFolder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.compactDate(record.startedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
            }
            HStack(spacing: 4) {
                if record.duration > 0 {
                    Text("\(max(1, Int(record.duration / 60))) min")
                }
                if showsFolder, let folder = record.folder {
                    if record.duration > 0 { Text("·") }
                    Text(folder)
                }
                if record.duration == 0, !showsFolder || record.folder == nil {
                    Text(record.sourceApplication)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private static func compactDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

private struct NoteDetailView: View {
    private enum Tab: String {
        case notes = "Notes"
        case transcript = "Transcript"
    }

    @ObservedObject var model: AppModel
    let record: TranscriptRecord
    @State private var tab: Tab = .notes

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.title)
                        .font(.title.weight(.semibold))
                        .textSelection(.enabled)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 20)

                if visibleTab == .notes, let analysis = record.analysis {
                    MarkdownSectionsView(markdown: analysis)
                } else {
                    TranscriptView(text: record.text)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(record.id)
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .principal) {
                if record.analysis != nil {
                    Picker("Section", selection: Binding(get: { visibleTab }, set: { tab = $0 })) {
                        Text(Tab.notes.rawValue).tag(Tab.notes)
                        Text(Tab.transcript.rawValue).tag(Tab.transcript)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
            ToolbarItemGroup {
                Button("Copy", systemImage: "doc.on.doc") {
                    if visibleTab == .notes, let analysis = record.analysis {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(analysis, forType: .string)
                    } else {
                        model.copyTranscript(record)
                    }
                }
                .help(visibleTab == .notes ? "Copy meeting notes" : "Copy transcript")
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([record.markdownURL])
                }
                .help("Show the note file in Finder")
            }
        }
    }

    // Notes-less records (legacy imports, analysis disabled) read as
    // transcript-only regardless of the picker's stored state.
    private var visibleTab: Tab {
        record.analysis == nil ? .transcript : tab
    }

    private var subtitle: String {
        var parts = [record.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if record.duration > 0 {
            parts.append("\(max(1, Int(record.duration / 60))) min")
        }
        parts.append(record.sourceApplication)
        if let folder = record.folder {
            parts.append(folder)
        }
        return parts.joined(separator: "  ·  ")
    }
}

// A deliberately small renderer for the note's known shapes: "##" headings,
// bullets, checkboxes, and paragraphs, with inline Markdown inside each line.
private struct MarkdownSectionsView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("## ") {
                    Text(String(trimmed.dropFirst(3)))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.top, index == 0 ? 0 : 14)
                } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: trimmed.hasPrefix("- [x] ") ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12))
                            .foregroundStyle(trimmed.hasPrefix("- [x] ") ? Color.accentColor : Color.secondary)
                        inlineText(String(trimmed.dropFirst(6)))
                    }
                    .padding(.leading, 2)
                } else if trimmed.hasPrefix("- ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(.tertiary)
                            .frame(width: 4, height: 4)
                            .offset(y: -3)
                        inlineText(String(trimmed.dropFirst(2)))
                    }
                    .padding(.leading, 2)
                } else if !trimmed.isEmpty {
                    inlineText(trimmed)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inlineText(_ line: String) -> some View {
        Text((try? AttributedString(markdown: line)) ?? AttributedString(line))
            .font(.body)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Renders "**Speaker** [0:00]" blocks as a conversation: speaker and time on
// a quiet label line, the utterance as readable body text.
private struct TranscriptView: View {
    private struct Block: Identifiable {
        let id: Int
        let speaker: String?
        let timestamp: String?
        let text: String
    }

    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(blocks) { block in
                VStack(alignment: .leading, spacing: 4) {
                    if let speaker = block.speaker {
                        HStack(spacing: 6) {
                            Text(speaker)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(speaker == "Me" ? Color.accentColor : Color.secondary)
                            if let timestamp = block.timestamp {
                                Text(timestamp)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Text(block.text)
                        .font(.body)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [Block] {
        text.components(separatedBy: "\n\n").enumerated().map { index, paragraph in
            let lines = paragraph.components(separatedBy: "\n")
            if let header = lines.first,
               header.hasPrefix("**"),
               let nameEnd = header.range(of: "**", range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex) {
                let speaker = String(header[header.index(header.startIndex, offsetBy: 2)..<nameEnd.lowerBound])
                let remainder = header[nameEnd.upperBound...].trimmingCharacters(in: .whitespaces)
                let timestamp = remainder.hasPrefix("[") && remainder.hasSuffix("]")
                    ? String(remainder.dropFirst().dropLast())
                    : nil
                return Block(
                    id: index,
                    speaker: speaker,
                    timestamp: timestamp,
                    text: lines.dropFirst().joined(separator: "\n")
                )
            }
            return Block(id: index, speaker: nil, timestamp: nil, text: paragraph)
        }
    }
}
