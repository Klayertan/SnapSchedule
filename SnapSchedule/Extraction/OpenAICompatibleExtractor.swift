import Foundation

/// Talks to any server that speaks the OpenAI chat-completions format: hosted services such as
/// Sakura AI Engine, or a self-hosted model served with vLLM, Ollama and the like.
enum OpenAICompatibleExtractor {
    static func extract(layout: String, images: [Data], settings: ExtractionSettings) async throws -> [RawEvent] {
        var address = settings.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while address.hasSuffix("/") { address.removeLast() }
        if !address.hasSuffix("/chat/completions") { address += "/chat/completions" }
        guard let url = URL(string: address) else {
            throw ExtractionError.notConfigured("The AI server address is not a valid URL.")
        }

        let system = [
            ScheduleExtractor.instructions(userContext: settings.userContext),
            ScheduleExtractor.layoutGuide,
            ScheduleExtractor.jsonGuide,
        ].joined(separator: "\n\n")
        let prompt = "Extract the calendar events from this source.\n\n" + layout

        let userContent: Any
        if images.isEmpty {
            userContent = prompt
        } else {
            userContent = [["type": "text", "text": prompt]] + images.map {
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]]
            }
        }
        let body: [String: Any] = [
            "model": settings.customModel,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent],
            ],
        ]

        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.customKey.isEmpty {
            request.setValue("Bearer \(settings.customKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ExtractionError.badResponse }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
                ?? String(data: data.prefix(300), encoding: .utf8)
            throw ExtractionError.api("HTTP \(http.statusCode). \(message ?? "")")
        }

        guard let completion = try? JSONDecoder().decode(Completion.self, from: data),
              let choice = completion.choices.first, let content = choice.message.content
        else { throw ExtractionError.badResponse }
        if choice.finish_reason == "length" { throw ExtractionError.truncated }

        // Models often wrap the JSON in a code fence or put reasoning before it.
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end,
              let schedule = try? JSONDecoder().decode(RawSchedule.self, from: Data(content[start...end].utf8))
        else { throw ExtractionError.badResponse }
        return schedule.events
    }

    private struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finish_reason: String?
        }
        let choices: [Choice]
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}
