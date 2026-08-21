import AVFoundation
import Foundation

struct TranscriptionResult: Sendable {
    let text: String
    let cost: Double?
}

struct TimedTranscriptChunk: Equatable, Sendable {
    let offset: TimeInterval
    let text: String
}

struct DualTrackTranscription: Sendable {
    let me: [TimedTranscriptChunk]
    let them: [TimedTranscriptChunk]
    let cost: Double?

    var isEmpty: Bool { me.isEmpty && them.isEmpty }
}

enum TranscriptionError: LocalizedError {
    case invalidResponse
    case server(statusCode: Int, message: String)
    case emptyTranscript
    case couldNotSplitAudio

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OpenRouter returned an unreadable response."
        case let .server(statusCode, message):
            return "OpenRouter returned \(statusCode): \(message)"
        case .emptyTranscript:
            return "OpenRouter returned an empty transcript."
        case .couldNotSplitAudio:
            return "The recording could not be prepared for transcription."
        }
    }
}

struct TranscriptionClient: Sendable {
    private let session: URLSession
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    private let singleTrackChunkDuration: TimeInterval = 8 * 60
    // Speaker turns interleave at chunk granularity, so per-source tracks use
    // short chunks; the combined fallback keeps long ones to reduce requests.
    private let trackChunkDuration: TimeInterval = 2 * 60

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(
        fileURL: URL,
        apiKey: String,
        model: String,
        language: String? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> TranscriptionResult {
        let chunks = try await splitIntoChunks(fileURL, chunkDuration: singleTrackChunkDuration)
        defer { cleanUp(chunks, source: fileURL) }

        var transcriptParts: [String] = []
        var totalCost: Double = 0
        var receivedCost = false

        for (index, chunk) in chunks.enumerated() {
            let result = try await transcribeChunk(chunk.url, apiKey: apiKey, model: model, language: language)
            transcriptParts.append(result.text)
            if let cost = result.cost {
                totalCost += cost
                receivedCost = true
            }
            await progress(Double(index + 1) / Double(chunks.count))
        }

        let text = transcriptParts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
        return TranscriptionResult(text: text, cost: receivedCost ? totalCost : nil)
    }

    // Transcribes the Me and Them tracks as independent timed chunks. Silent
    // chunks are dropped before upload: Whisper reliably hallucinates filler
    // ("Thank you.") on near-silent audio, and the mic track is silent for
    // every stretch where the user is just listening.
    func transcribeDualTrack(
        microphoneURL: URL,
        systemURL: URL,
        apiKey: String,
        model: String,
        language: String? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> DualTrackTranscription {
        let microphoneChunks = try await splitIntoChunks(microphoneURL, chunkDuration: trackChunkDuration)
        let systemChunks = try await splitIntoChunks(systemURL, chunkDuration: trackChunkDuration)
        defer {
            cleanUp(microphoneChunks, source: microphoneURL)
            cleanUp(systemChunks, source: systemURL)
        }

        let audibleMicrophone = microphoneChunks.filter { Self.isAudible($0.url) }
        let audibleSystem = systemChunks.filter { Self.isAudible($0.url) }
        let total = audibleMicrophone.count + audibleSystem.count
        guard total > 0 else {
            return DualTrackTranscription(me: [], them: [], cost: nil)
        }

        var completed = 0
        var totalCost: Double = 0
        var receivedCost = false

        func transcribeAll(_ chunks: [AudioChunk]) async throws -> [TimedTranscriptChunk] {
            var results: [TimedTranscriptChunk] = []
            for chunk in chunks {
                let result = try await transcribeChunk(chunk.url, apiKey: apiKey, model: model, language: language)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    results.append(TimedTranscriptChunk(offset: chunk.offset, text: text))
                }
                if let cost = result.cost {
                    totalCost += cost
                    receivedCost = true
                }
                completed += 1
                let fraction = Double(completed) / Double(total)
                await progress(fraction)
            }
            return results
        }

        let me = try await transcribeAll(audibleMicrophone)
        let them = try await transcribeAll(audibleSystem)
        return DualTrackTranscription(me: me, them: them, cost: receivedCost ? totalCost : nil)
    }

    // Language is pinned when the caller knows it: Whisper detects language
    // from the first ~30 seconds of each upload and applies it to the whole
    // file, so one greeting in another language turns an entire chunk into
    // that language. Segments are requested (verbose_json) so hallucinated
    // filler can be dropped per segment; providers that reject that format
    // get a plain json retry and a text-level filter instead.
    private func transcribeChunk(
        _ url: URL,
        apiKey: String,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult {
        let audioData = try Data(contentsOf: url, options: .mappedIfSafe)
        let base64 = audioData.base64EncodedString()
        let pinnedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)

        var lastError: (any Error)?
        var verbose = true
        for delay in [UInt64(0), 2, 5] {
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            let requestBody = RequestBody(
                model: model,
                language: (pinnedLanguage?.isEmpty ?? true) ? nil : pinnedLanguage,
                temperature: 0,
                responseFormat: verbose ? "verbose_json" : "json",
                inputAudio: .init(data: base64, format: "m4a")
            )
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Meeting Recorder", forHTTPHeaderField: "X-OpenRouter-Title")
            request.httpBody = try JSONEncoder().encode(requestBody)
            request.timeoutInterval = 120

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw TranscriptionError.invalidResponse
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error.message)
                        ?? String(data: data, encoding: .utf8)
                        ?? "Unknown error"
                    throw TranscriptionError.server(statusCode: httpResponse.statusCode, message: message)
                }

                let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
                let text: String
                if let segments = decoded.segments, !segments.isEmpty {
                    text = TranscriptHallucinationFilter.clean(segments: segments.map(\.text))
                        .joined(separator: " ")
                } else {
                    text = TranscriptHallucinationFilter.clean(text: decoded.text)
                }
                return TranscriptionResult(text: text, cost: decoded.usage?.cost)
            } catch {
                lastError = error
                if case TranscriptionError.server(let status, _) = error {
                    if status == 401 || status == 402 { throw error }
                    // Only OpenAI-compatible providers accept verbose_json.
                    if status == 400, verbose { verbose = false }
                }
            }
        }
        throw lastError ?? TranscriptionError.invalidResponse
    }

    private struct AudioChunk: Sendable {
        let offset: TimeInterval
        let url: URL
    }

    private func splitIntoChunks(_ url: URL, chunkDuration: TimeInterval) async throws -> [AudioChunk] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        // Imported files can be mp3/wav/etc.; every uploaded chunk is m4a, so
        // short non-m4a sources fall through to the export loop (one pass).
        guard duration > chunkDuration || url.pathExtension.lowercased() != "m4a" else {
            return [AudioChunk(offset: 0, url: url)]
        }

        var chunks: [AudioChunk] = []
        var offset: TimeInterval = 0
        while offset < duration {
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw TranscriptionError.couldNotSplitAudio
            }
            let outputURL = FileManager.default.temporaryDirectory
                .appending(path: "meeting-recorder-\(UUID().uuidString).m4a")
            let remaining = min(chunkDuration, duration - offset)
            exporter.timeRange = CMTimeRange(
                start: CMTime(seconds: offset, preferredTimescale: 600),
                duration: CMTime(seconds: remaining, preferredTimescale: 600)
            )
            do {
                try await exporter.export(to: outputURL, as: .m4a)
                chunks.append(AudioChunk(offset: offset, url: outputURL))
            } catch {
                cleanUp(chunks, source: url)
                throw TranscriptionError.couldNotSplitAudio
            }
            offset += remaining
        }
        return chunks
    }

    private func cleanUp(_ chunks: [AudioChunk], source: URL) {
        for chunk in chunks where chunk.url != source {
            try? FileManager.default.removeItem(at: chunk.url)
        }
    }

    // Returns whether any block of the file rises above roughly -50 dBFS RMS.
    // Errors err toward audible so a decode problem never drops real speech.
    static func isAudible(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return true }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else {
            return true
        }

        let threshold: Float = 0.003
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer)
            } catch {
                return true
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(format.channelCount) {
                var sum: Float = 0
                let data = channels[channel]
                for index in 0..<frames {
                    sum += data[index] * data[index]
                }
                if (sum / Float(frames)).squareRoot() > threshold { return true }
            }
        }
        return false
    }
}

private struct RequestBody: Encodable {
    struct InputAudio: Encodable {
        let data: String
        let format: String
    }

    let model: String
    let language: String?
    let temperature: Double
    let responseFormat: String
    let inputAudio: InputAudio

    enum CodingKeys: String, CodingKey {
        case model
        case language
        case temperature
        case responseFormat = "response_format"
        case inputAudio = "input_audio"
    }
}

private struct ResponseBody: Decodable {
    struct Usage: Decodable {
        let cost: Double?
    }

    struct Segment: Decodable {
        let text: String
    }

    let text: String
    let usage: Usage?
    let segments: [Segment]?
}

private struct ErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
