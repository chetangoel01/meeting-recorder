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
    @State private var recordToRename: TranscriptRecord?
    @State private var renameTitle = ""
    @State private var folderToRename: String?
    @State private var folderRenameText = ""
    @State private var folderToDelete: String?
    @FocusState private var searchFocused: Bool

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
        .dropDestination(for: URL.self) { urls, _ in
            guard model.phase.isIdle, let url = urls.first else { return false }
            model.importMeeting(from: url)
            return true
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
        .alert(model.libraryAlert ?? "", isPresented: Binding(
            get: { model.libraryAlert != nil },
            set: { if !$0 { model.libraryAlert = nil } }
        )) {
            Button("OK", role: .cancel) {}
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
                            .contextMenu {
                                Button("Rename Folder…") {
                                    folderRenameText = folder
                                    folderToRename = folder
                                }
                                Button("Delete Folder…", role: .destructive) {
                                    folderToDelete = folder
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Meetings")
        .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        // Notes-style footer: app-level actions live at the bottom of the
        // sidebar where the narrow toolbar can't crowd them — New Folder and
        // Import on the left, Settings on the right.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 16) {
                Button {
                    recordAwaitingFolder = nil
                    newFolderPrompted = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("New folder")
                Button(action: model.presentImportPanel) {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(!model.phase.isIdle)
                .help("Import an audio recording or a transcript file — or drop one on this window")
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .alert("Rename folder", isPresented: Binding(
            get: { folderToRename != nil },
            set: { if !$0 { folderToRename = nil } }
        )) {
            TextField("Folder name", text: $folderRenameText)
            Button("Rename") {
                if let folder = folderToRename,
                   let renamed = model.renameFolder(folder, to: folderRenameText),
                   selection == .folder(folder) {
                    selection = .folder(renamed)
                }
                folderToRename = nil
            }
            Button("Cancel", role: .cancel) { folderToRename = nil }
        }
        .alert("Delete “\(folderToDelete ?? "")”?", isPresented: Binding(
            get: { folderToDelete != nil },
            set: { if !$0 { folderToDelete = nil } }
        )) {
            Button("Delete Folder", role: .destructive) {
                if let folder = folderToDelete {
                    model.deleteFolder(folder)
                    if selection == .folder(folder) { selection = .unfiled }
                }
                folderToDelete = nil
            }
            Button("Cancel", role: .cancel) { folderToDelete = nil }
        } message: {
            Text("The meetings inside move to Unfiled. No meetings are deleted.")
        }
    }

    private var recordList: some View {
        List(selection: $selectedRecordID) {
            if let status = model.processingStatus {
                ProcessingRow(status: status)
                    .selectionDisabled()
            }
            ForEach(filteredRecords) { record in
                MeetingRow(record: record, showsFolder: selection == .all)
                    .tag(record.id)
                    .contextMenu { contextMenu(for: record) }
            }
        }
        .listStyle(.inset)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search meetings")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusToken) { searchFocused = true }
        .onDeleteCommand(perform: deleteSelectedRecord)
        .overlay {
            if filteredRecords.isEmpty, model.processingStatus == nil {
                if searchText.isEmpty {
                    ContentUnavailableView {
                        Label("No meetings here", systemImage: "waveform")
                    } description: {
                        Text("Completed meeting notes will appear here. Record from the menu bar, import a file, or drop one on this window.")
                    } actions: {
                        Button("Import Meeting…", action: model.presentImportPanel)
                            .disabled(!model.phase.isIdle)
                    }
                } else {
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "magnifyingglass",
                        description: Text("No meeting titles or transcripts contain “\(searchText)”.")
                    )
                }
            }
        }
        .alert("Rename meeting", isPresented: Binding(
            get: { recordToRename != nil },
            set: { if !$0 { recordToRename = nil } }
        )) {
            TextField("Title", text: $renameTitle)
            Button("Rename") {
                if let record = recordToRename {
                    model.renameTranscript(record, to: renameTitle)
                }
                recordToRename = nil
            }
            Button("Cancel", role: .cancel) { recordToRename = nil }
        }
    }

    @ViewBuilder
    private func contextMenu(for record: TranscriptRecord) -> some View {
        Button("Rename…") {
            renameTitle = record.title
            recordToRename = record
        }
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
        Divider()
        Button("Regenerate Notes") { model.regenerateNotes(for: record) }
            .disabled(model.regeneratingNoteIDs.contains(record.id))
        Button("Copy transcript") { model.copyTranscript(record) }
        if model.obsidianVaultURL != nil {
            Button("Open in Obsidian") { model.openInObsidian(record) }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([record.markdownURL])
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            if selectedRecordID == record.id { selectedRecordID = nil }
            model.deleteTranscript(record)
        }
    }

    // Delete key / ⌘⌫ on the focused list: trash the selection and keep the
    // user in the list by selecting the nearest neighbor.
    private func deleteSelectedRecord() {
        guard let record = selectedRecord else { return }
        let records = filteredRecords
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            if index + 1 < records.count {
                selectedRecordID = records[index + 1].id
            } else if index > 0 {
                selectedRecordID = records[index - 1].id
            } else {
                selectedRecordID = nil
            }
        }
        model.deleteTranscript(record)
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

// The in-flight meeting, pinned above finished ones so recordings and imports
// visibly land in the library instead of appearing out of nowhere.
private struct ProcessingRow: View {
    let status: ProcessingStatus

    var body: some View {
        HStack(spacing: 10) {
            if let progress = status.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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
    @ObservedObject var model: AppModel
    let record: TranscriptRecord
    @State private var infoPresented = false
    @State private var renamePrompted = false
    @State private var renameTitle = ""

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

                if visibleTab == .notes {
                    if model.regeneratingNoteIDs.contains(record.id) {
                        StatusCard {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Writing notes…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if let failure = record.analysisFailureMessage {
                        StatusCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("No meeting notes")
                                    .font(.headline)
                                Text(failure)
                                    .foregroundStyle(.secondary)
                                Button("Regenerate Notes") {
                                    model.regenerateNotes(for: record)
                                }
                            }
                        }
                    } else if let analysis = record.analysis {
                        MarkdownSectionsView(markdown: analysis)
                    }
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
                    Picker("Section", selection: Binding(
                        get: { visibleTab },
                        set: { model.noteTab = $0 }
                    )) {
                        Text(NoteTab.notes.rawValue).tag(NoteTab.notes)
                        Text(NoteTab.transcript.rawValue).tag(NoteTab.transcript)
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

                Button("Info", systemImage: "info.circle") {
                    infoPresented.toggle()
                }
                .help("Meeting details")
                .popover(isPresented: $infoPresented, arrowEdge: .bottom) {
                    MeetingInfoView(record: record)
                }

                Menu {
                    Button("Regenerate Notes", systemImage: "arrow.clockwise") {
                        model.regenerateNotes(for: record)
                    }
                    .disabled(model.regeneratingNoteIDs.contains(record.id))
                    Button("Rename…", systemImage: "pencil") {
                        renameTitle = record.title
                        renamePrompted = true
                    }
                    Divider()
                    if model.obsidianVaultURL != nil {
                        Button("Open in Obsidian", systemImage: "arrow.up.forward.app") {
                            model.openInObsidian(record)
                        }
                    }
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([record.markdownURL])
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .help("More actions")
            }
        }
        .alert("Rename meeting", isPresented: $renamePrompted) {
            TextField("Title", text: $renameTitle)
            Button("Rename") { model.renameTranscript(record, to: renameTitle) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // Notes-less records (legacy imports, analysis disabled) read as
    // transcript-only regardless of the picker's stored state.
    private var visibleTab: NoteTab {
        record.analysis == nil ? .transcript : model.noteTab
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

// A quiet in-document card for non-content states (regenerating, failed
// analysis) so errors live where the notes would be, with the fix in reach.
private struct StatusCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5))
            )
    }
}

// Metadata that informs but isn't read every visit: kept out of the header,
// one ⓘ away.
private struct MeetingInfoView: View {
    let record: TranscriptRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow("Recorded", record.startedAt.formatted(date: .abbreviated, time: .shortened))
            if record.duration > 0 {
                infoRow("Duration", "\(max(1, Int(record.duration / 60))) min")
            }
            infoRow("Source", record.sourceApplication)
            infoRow("Folder", record.folder ?? "Unfiled")
            if !record.attendees.isEmpty {
                infoRow("Attendees", record.attendees.joined(separator: "\n"))
            }
            if let cost = record.cost {
                infoRow("Cost", String(format: "$%.4f", cost))
            }
            Divider()
            HStack(spacing: 8) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([record.markdownURL])
                }
                if let audioURL = record.audioURL,
                   FileManager.default.fileExists(atPath: audioURL.path) {
                    Button("Show Audio") {
                        NSWorkspace.shared.activateFileViewerSelecting([audioURL])
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
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
