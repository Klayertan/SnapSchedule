import Foundation

/// Sends the picture or PDF to the Claude Messages API and gets schema-constrained JSON back.
enum ClaudeExtractor {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-opus-5-5"

    static func extract(input: ScanInput, apiKey: String, userContext: String) async throws -> [RawEvent] {
        var request = URLRequest(url: endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(input: input, userContext: userContext))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ExtractionError.badResponse }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error.message
            throw ExtractionError.api(message ?? "HTTP \(http.statusCode)")
        }

        let message = try JSONDecoder().decode(MessageResponse.self, from: data)
        switch message.stop_reason {
        case "refusal": throw ExtractionError.refused
        case "max_tokens": throw ExtractionError.truncated
        default: break
        }
        // Thinking blocks come first; the JSON is in the text block.
        guard let text = message.content.first(where: { $0.type == "text" })?.text,
              let schedule = try? JSONDecoder().decode(RawSchedule.self, from: Data(text.utf8))
        else { throw ExtractionError.badResponse }
        return schedule.events
    }

    private static func body(input: ScanInput, userContext: String) -> [String: Any] {
        // A PDF goes up as-is so Claude gets both its text and its pages; pictures go up as JPEG.
        let source: [String: Any]
        if let pdf = input.pdfData {
            source = [
                "type": "document",
                "source": ["type": "base64", "media_type": "application/pdf", "data": pdf.base64EncodedString()],
            ]
        } else {
            source = [
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": input.pageJPEGs.first?.base64EncodedString() ?? ""],
            ]
        }
        return [
            "model": model,
            "max_tokens": 16000,
            // If a safety classifier declines the request, retry server-side on Anthropic's recommended fallback model.
            "fallbacks": "default",
            "system": ScheduleExtractor.instructions(userContext: userContext),
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [[
                "role": "user",
                "content": [source, ["type": "text", "text": "Extract the calendar events from this source."]],
            ]],
        ]
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "events": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "start": ["type": "string"],
                        "end": ["type": "string"],
                        "allDay": ["type": "boolean"],
                        "location": ["type": "string"],
                        "notes": ["type": "string"],
                        "repeatsWeekly": ["type": "boolean"],
                    ],
                    "required": ["title", "start", "end", "allDay", "location", "notes", "repeatsWeekly"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["events"],
        "additionalProperties": false,
    ]

    private struct MessageResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
    }

    private struct APIErrorEnvelope: Decodable {
        struct APIError: Decodable { let message: String }
        let error: APIError
    }
}
