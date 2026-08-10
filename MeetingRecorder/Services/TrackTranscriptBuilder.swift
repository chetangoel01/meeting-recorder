import Foundation

// Builds the transcript body from per-source timed chunks. Attribution is at
// chunk granularity: each block is everything one side said during that chunk,
// ordered by when the chunk started in the shared recording timeline.
struct TrackTranscriptBuilder {
    static func markdown(
        me: [TimedTranscriptChunk],
        them: [TimedTranscriptChunk]
    ) -> String {
        struct Block {
            let speaker: String
            let offset: TimeInterval
            var texts: [String]
        }

        let labeled = me.map { (speaker: "Me", chunk: $0) } + them.map { (speaker: "Them", chunk: $0) }
        let ordered = labeled.sorted {
            if $0.chunk.offset != $1.chunk.offset { return $0.chunk.offset < $1.chunk.offset }
            // Equal offsets mean both sides spoke in the same chunk window;
            // keep Them first so replies from "Me" read as responses.
            return $0.speaker > $1.speaker
        }

        var blocks: [Block] = []
        for entry in ordered {
            if var last = blocks.last, last.speaker == entry.speaker {
                last.texts.append(entry.chunk.text)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(
                    Block(speaker: entry.speaker, offset: entry.chunk.offset, texts: [entry.chunk.text])
                )
            }
        }

        return blocks
            .map { "**\($0.speaker)** [\(timestamp($0.offset))]\n\($0.texts.joined(separator: "\n\n"))" }
            .joined(separator: "\n\n")
    }

    static func timestamp(_ offset: TimeInterval) -> String {
        let total = max(0, Int(offset.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
