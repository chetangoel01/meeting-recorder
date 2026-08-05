import AVFoundation
import Foundation

struct TranscriptionResult: Sendable {
    let text: String
    let cost: Double?
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
    private let chunkDuration: TimeInterval = 8 * 60

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(
        fileURL: URL,
        apiKey: String,
        model: String,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> TranscriptionResult {
        let chunks = try await splitIfNeeded(fileURL)
        defer {
            for chunk in chunks where chunk != fileURL {
                try? FileManager.default.removeItem(at: chunk)
            }
        }

        var transcriptParts: [String] = []
        var totalCost: Double = 0
        var receivedCost = false

        for (index, chunk) in chunks.enumerated() {
            let result = try await transcribeChunk(chunk, apiKey: apiKey, model: model)
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

    private func transcribeChunk(_ url: URL, apiKey: String, model: String) async throws -> TranscriptionResult {
        let audioData = try Data(contentsOf: url, options: .mappedIfSafe)
        let requestBody = RequestBody(
            model: model,
            inputAudio: .init(data: audioData.base64EncodedString(), format: "m4a")
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Meeting Recorder", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.timeoutInterval = 120

        var lastError: (any Error)?
        for delay in [UInt64(0), 2, 5] {
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw TranscriptionError.invalidResponse
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error.message)
                        ?? String(data: data, encoding: .utf8)
                        ?? "Unknown error"
                    if httpResponse.statusCode == 401 || httpResponse.statusCode == 402 {
                        throw TranscriptionError.server(statusCode: httpResponse.statusCode, message: message)
                    }
                    throw TranscriptionError.server(statusCode: httpResponse.statusCode, message: message)
                }

                let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
                return TranscriptionResult(text: decoded.text, cost: decoded.usage?.cost)
            } catch {
                lastError = error
                if case TranscriptionError.server(let status, _) = error, status == 401 || status == 402 {
                    throw error
                }
            }
        }
        throw lastError ?? TranscriptionError.invalidResponse
    }

    private func splitIfNeeded(_ url: URL) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > chunkDuration else { return [url] }

        var chunks: [URL] = []
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
                chunks.append(outputURL)
            } catch {
                for chunk in chunks { try? FileManager.default.removeItem(at: chunk) }
                throw TranscriptionError.couldNotSplitAudio
            }
            offset += remaining
        }
        return chunks
    }
}

private struct RequestBody: Encodable {
    struct InputAudio: Encodable {
        let data: String
        let format: String
    }

    let model: String
    let inputAudio: InputAudio

    enum CodingKeys: String, CodingKey {
        case model
        case inputAudio = "input_audio"
    }
}

private struct ResponseBody: Decodable {
    struct Usage: Decodable {
        let cost: Double?
    }

    let text: String
    let usage: Usage?
}

private struct ErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
