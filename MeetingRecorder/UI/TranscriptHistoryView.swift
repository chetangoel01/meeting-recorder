import SwiftUI

struct TranscriptHistoryView: View {
    @ObservedObject var model: AppModel
    @State private var selection: TranscriptRecord.ID?

    var body: some View {
        NavigationSplitView {
            List(model.transcripts, selection: $selection) { record in
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(record.startedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(record.id)
            }
            .navigationTitle("Transcripts")
            .overlay {
                if model.transcripts.isEmpty {
                    ContentUnavailableView(
                        "No transcripts yet",
                        systemImage: "waveform",
                        description: Text("Your completed meeting transcripts will appear here.")
                    )
                }
            }
        } detail: {
            if let record = selectedRecord {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title)
                                .font(.title2.weight(.semibold))
                            Text("\(record.sourceApplication) · \(record.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") {
                            model.copyTranscript(record)
                        }
                        Button("Show file", systemImage: "arrow.forward.square") {
                            NSWorkspace.shared.activateFileViewerSelecting([record.markdownURL])
                        }
                    }
                    .padding(20)

                    Divider()

                    ScrollView {
                        Text(record.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: 680, alignment: .leading)
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Select a transcript",
                    systemImage: "text.document",
                    description: Text("Choose a meeting from the sidebar.")
                )
            }
        }
        .onAppear {
            selection = selection ?? model.transcripts.first?.id
        }
    }

    private var selectedRecord: TranscriptRecord? {
        model.transcripts.first { $0.id == selection }
    }
}
