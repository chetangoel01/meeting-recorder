import Foundation

struct AnalysisContext: Sendable {
    let fallbackTitle: String
    let sourceApplication: String
    let startedAt: Date
    let duration: TimeInterval
    let calendarEvent: MatchedCalendarEvent?
    let existingFolders: [String]
}

struct AnalysisOutcome: Equatable, Sendable {
    let title: String?
    let analysisMarkdown: String
    let suggestedFolder: String?

    // The model's reply carries routing on two leading lines ("Title:" and
    // "Folder:") followed by the note sections. Both lines are optional and a
    // malformed reply still yields usable analysis — never a pipeline failure.
    static func parse(_ response: String, existingFolders: [String]) -> AnalysisOutcome {
        var lines = response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
        var title: String?
        var folder: String?

        while let first = lines.first?.trimmingCharacters(in: .whitespaces) {
            if first.lowercased().hasPrefix("title:") {
                let value = String(first.dropFirst("title:".count)).trimmingCharacters(in: .whitespaces)
                title = value.isEmpty ? nil : value
                lines.removeFirst()
            } else if first.lowercased().hasPrefix("folder:") {
                let value = String(first.dropFirst("folder:".count)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty, value.lowercased() != "none" {
                    folder = existingFolders.first { $0.caseInsensitiveCompare(value) == .orderedSame }
                        ?? TranscriptStore.safeFolderName(value)
                }
                lines.removeFirst()
            } else if first.isEmpty {
                lines.removeFirst()
            } else {
                break
            }
        }

        let markdown = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return AnalysisOutcome(
            title: title,
            analysisMarkdown: markdown,
            suggestedFolder: folder?.isEmpty == true ? nil : folder
        )
    }
}

struct AnalysisClient: Sendable {
    private let session: URLSession
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    // Very long meetings are truncated from the front: endings hold the
    // decisions and action items, which is what the analysis is for.
    private let maximumTranscriptCharacters = 240_000

    init(session: URLSession = .shared) {
        self.session = session
    }

    func analyze(
        transcript: String,
        context: AnalysisContext,
        apiKey: String,
        model: String,
        instructions: String = AnalysisClient.defaultInstructions
    ) async throws -> (outcome: AnalysisOutcome, cost: Double?) {
        var trimmedTranscript = transcript
        if trimmedTranscript.count > maximumTranscriptCharacters {
            trimmedTranscript = "[Earlier portion omitted]\n\n"
                + String(trimmedTranscript.suffix(maximumTranscriptCharacters))
        }

        let requestBody = RequestBody(
            model: model,
            messages: [
                .init(role: "system", content: Self.systemPrompt(instructions: instructions)),
                .init(role: "user", content: Self.userPrompt(transcript: trimmedTranscript, context: context)),
            ]
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Meeting Recorder", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.timeoutInterval = 180

        var lastError: (any Error)?
        for delay in [UInt64(0), 3] {
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
                    throw TranscriptionError.server(statusCode: httpResponse.statusCode, message: message)
                }
                let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
                guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
                    throw TranscriptionError.invalidResponse
                }
                return (
                    AnalysisOutcome.parse(content, existingFolders: context.existingFolders),
                    decoded.usage?.cost
                )
            } catch {
                lastError = error
                if case TranscriptionError.server(let status, _) = error, status == 401 || status == 402 {
                    throw error
                }
            }
        }
        throw lastError ?? TranscriptionError.invalidResponse
    }

    // The user-editable half of the system prompt. The reply-shape contract
    // (Title:/Folder: routing lines) is appended in code so a customized
    // prompt can change tone and sections without breaking parsing.
    static let defaultInstructions = """
    You turn raw meeting transcripts into meeting notes detailed enough to replace attending \
    the meeting. In the transcript, "Me" is the person who recorded it and "Them" is everyone \
    else on the call; transcripts without labels contain both sides mixed together.

    Write these Markdown sections, omitting any section that would be empty:

    ## Summary
    A thorough narrative of the meeting, one paragraph per major topic in the order discussed. \
    For each topic cover what was proposed, the reasoning and any disagreement, and how it \
    resolved. Length should scale with the meeting: a quick call may need one paragraph, a \
    long working session six or more. Do not compress to the point of losing substance.

    ## Key details
    Bullets for concrete specifics worth finding again later: numbers, dates, names, amounts, \
    deadlines, links, and exact commitments, quoted or closely paraphrased.

    ## Decisions
    One bullet per decision actually made, with enough context to stand alone.

    ## Action items
    - [ ] Task — owner if stated, due date if stated.

    ## Open questions
    One bullet per unresolved question or explicitly deferred topic.

    Never invent facts, decisions, owners, or dates that are not in the transcript. Ignore \
    transcription artifacts such as stray filler phrases on otherwise silent audio.
    """

    static func systemPrompt(instructions: String) -> String {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? defaultInstructions : trimmed
        return """
        \(effective)

        Reply in exactly this shape, with no preamble:

        Title: <a short specific meeting title, at most 8 words>
        Folder: <the best-fitting folder from the provided list, or a sensible new \
        one-or-two-word folder name, or "none">

        <your meeting notes as Markdown sections>
        """
    }

    static func userPrompt(transcript: String, context: AnalysisContext) -> String {
        var details = [
            "Working title: \(context.fallbackTitle)",
            "Meeting client: \(context.sourceApplication)",
            "Recorded: \(MeetingNote.isoString(from: context.startedAt))",
            "Duration: \(Int(context.duration / 60)) minutes",
        ]
        if let event = context.calendarEvent {
            details.append("Calendar event: \(event.title)")
            if !event.attendees.isEmpty {
                details.append("Attendees: \(event.attendees.joined(separator: ", "))")
            }
        }
        details.append(
            context.existingFolders.isEmpty
                ? "Existing folders: none yet"
                : "Existing folders: \(context.existingFolders.joined(separator: ", "))"
        )

        return """
        \(details.joined(separator: "\n"))

        Transcript:

        \(transcript)
        """
    }
}

private struct RequestBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
}

private struct ResponseBody: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    struct Usage: Decodable {
        let cost: Double?
    }

    let choices: [Choice]
    let usage: Usage?
}

private struct ErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
