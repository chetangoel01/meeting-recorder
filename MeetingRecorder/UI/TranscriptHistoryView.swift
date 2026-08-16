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
        }
    }

    private var recordList: some View {
        List(filteredRecords, selection: $selectedRecordID) { record in
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.startedAt, format: .dateTime.month().day().hour().minute())
                    if record.duration > 0 {
                        Text("·")
                        Text("\(max(1, Int(record.duration / 60))) min")
                    }
                    if case .all = selection, let folder = record.folder {
                        Text("·")
                        Label(folder, systemImage: "folder")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .tag(record.id)
            .contextMenu { moveMenu(for: record) }
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 270)
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

private struct NoteDetailView: View {
    private enum Tab: String {
        case notes = "Notes"
        case transcript = "Transcript"
    }

    @ObservedObject var model: AppModel
    let record: TranscriptRecord
    @State private var tab: Tab = .notes

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    if visibleTab == .notes, let analysis = record.analysis {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(analysis, forType: .string)
                    } else {
                        model.copyTranscript(record)
                    }
                }
                .help(visibleTab == .notes ? "Copy meeting notes" : "Copy transcript")
                Button("Show file", systemImage: "arrow.forward.square") {
                    NSWorkspace.shared.activateFileViewerSelecting([record.markdownURL])
                }
            }
            .padding(20)

            Picker("Section", selection: Binding(get: { visibleTab }, set: { tab = $0 })) {
                Text(Tab.notes.rawValue).tag(Tab.notes)
                Text(Tab.transcript.rawValue).tag(Tab.transcript)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .disabled(record.analysis == nil)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if visibleTab == .notes, let analysis = record.analysis {
                        MarkdownSectionsView(markdown: analysis)
                    } else {
                        TranscriptBodyView(text: record.text)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(record.id)
        }
    }

    // Notes-less records (legacy imports, analysis disabled) read as
    // transcript-only regardless of the picker's stored state.
    private var visibleTab: Tab {
        record.analysis == nil ? .transcript : tab
    }

    private var subtitle: String {
        var parts = [record.sourceApplication, record.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if record.duration > 0 {
            parts.append("\(max(1, Int(record.duration / 60))) min")
        }
        if let folder = record.folder {
            parts.append(folder)
        }
        return parts.joined(separator: " · ")
    }
}

// A deliberately small renderer for the note's known shapes: "##" headings,
// bullets, checkboxes, and paragraphs, with inline Markdown inside each line.
private struct MarkdownSectionsView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("## ") {
                    Text(String(trimmed.dropFirst(3)))
                        .font(.title3.weight(.semibold))
                        .padding(.top, 6)
                } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: trimmed.hasPrefix("- [x] ") ? "checkmark.square" : "square")
                            .foregroundStyle(.secondary)
                        inlineText(String(trimmed.dropFirst(6)))
                    }
                } else if trimmed.hasPrefix("- ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inlineText(String(trimmed.dropFirst(2)))
                    }
                } else if !trimmed.isEmpty {
                    inlineText(trimmed)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inlineText(_ line: String) -> Text {
        Text((try? AttributedString(markdown: line)) ?? AttributedString(line))
    }
}

private struct TranscriptBodyView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                Text((try? AttributedString(
                    markdown: paragraph,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )) ?? AttributedString(paragraph))
                .font(.body)
            }
        }
        .textSelection(.enabled)
    }
}
