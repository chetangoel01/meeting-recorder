import Foundation

// Whisper emits stock filler on silence, music, and room noise: "Thank you.",
// "you", "Bye.", "Thanks for watching." and the like, sometimes dozens of
// times in a row. OpenRouter's providers report no_speech_prob as 0 for every
// segment, so the only reliable signal is the text itself. This drops segments
// that are nothing but known filler and collapses loops of identical segments.
enum TranscriptHallucinationFilter {
    static let fillerPhrases: Set<String> = [
        "thank you", "thank you very much", "thank you so much", "thanks", "thanks a lot",
        "thank you for watching", "thanks for watching", "thank you for listening",
        "thanks for listening", "thank you for your attention",
        "you", "bye", "bye bye", "goodbye", "the end", "okay", "ok", "oh", "um", "uh", "hmm",
        "subscribe", "please subscribe", "like and subscribe", "please like and subscribe",
        "see you in the next video", "see you next time", "see you in the next one",
        "music", "applause", "laughter", "silence", "blank audio", "inaudible",
        "شکریہ", "धन्यवाद", "शुक्रिया", "gracias", "merci", "danke", "obrigado", "grazie",
        "ありがとうございました", "ご視聴ありがとうございました", "谢谢", "謝謝", "감사합니다",
    ]

    static func clean(segments: [String]) -> [String] {
        var kept: [String] = []
        var previous: String?
        for raw in segments {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isFiller(text) else { continue }
            let key = normalize(text)
            if key == previous { continue }
            previous = key
            kept.append(text)
        }
        return kept
    }

    // Plain-text fallback for providers that cannot return segments. Whisper
    // joins segments with two spaces, so that is the split point.
    static func clean(text: String) -> String {
        clean(segments: text.components(separatedBy: "  ")).joined(separator: " ")
    }

    static func isFiller(_ text: String) -> Bool {
        let key = normalize(text)
        guard !key.isEmpty else { return true }
        if fillerPhrases.contains(key) { return true }
        // "Thank you. Thank you. Thank you." inside a single segment.
        return fillerPhrases.contains { phrase in
            key.hasPrefix(phrase)
                && key.replacingOccurrences(of: phrase, with: "")
                    .trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                continue
            }
            scalars.append(scalar)
        }
        return String(scalars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
