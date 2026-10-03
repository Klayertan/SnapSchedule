import CoreGraphics
import Foundation
import FoundationModels
import Vision

/// Free, private extraction: Vision reads the text, then Apple Intelligence (or, when that is
/// unavailable, a date detector) turns it into events.
enum OnDeviceExtractor {
    static func recognizeText(in image: CGImage) async throws -> [TextChunk] {
        var request = RecognizeTextRequest()
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: image)
        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            // Vision's origin is bottom-left.
            let box = observation.boundingBox.cgRect
            return TextChunk(text: text, rect: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        }
    }

    static var isLanguageModelAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Why Apple Intelligence can't be used right now, in words the user can act on.
    static var languageModelProblem: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading its model. Check System Settings › Apple Intelligence & Siri and try again once it has finished."
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is turned off. Turn it on in System Settings › Apple Intelligence & Siri."
        case .unavailable(.deviceNotEligible): "This device does not support Apple Intelligence."
        default: "Apple Intelligence is not available right now."
        }
    }

    static func extractWithLanguageModel(lines: [String], userContext: String) async throws -> [RawEvent] {
        let session = LanguageModelSession(instructions: ScheduleExtractor.instructions(userContext: userContext))
        let prompt = "Text found in the source:\n\n" + lines.joined(separator: "\n")
        let response = try await session.respond(to: prompt, generating: GeneratedSchedule.self)
        let source = lines.joined(separator: "\n")
        return response.content.events.map {
            var event = RawEvent(title: $0.title, start: $0.start, end: $0.end, allDay: $0.allDay,
                                 location: $0.location, notes: $0.notes, repeatsWeekly: $0.repeatsWeekly)
            // The small model likes to make up a start time; keep one only if the source mentions it.
            if !event.allDay, let time = event.start.split(separator: "T").dropFirst().first,
               !mentions(time: String(time), in: source) {
                event.start = String(event.start.prefix(10))
                event.end = ""
                event.allDay = true
            }
            return event
        }
    }

    /// Whether a clock time such as "09:00" appears in the text in any common spelling.
    private static func mentions(time: String, in text: String) -> Bool {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        let (hour, minute) = (parts[0], parts[1])
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let minutes = String(format: "%02d", minute)
        var spellings = ["\(hour):\(minutes)", "\(hour)：\(minutes)", "\(hour)時", "\(hour12):\(minutes)", "\(hour12)時"]
        if minute == 0 {
            spellings += ["\(hour12)am", "\(hour12)pm", "\(hour12) am", "\(hour12) pm"]
        }
        let haystack = text.lowercased()
        return spellings.contains { haystack.contains($0) }
    }

    /// Last resort: every line containing a date becomes an event titled with the rest of the line.
    /// The whole text goes into the notes so nothing from the source is lost.
    static func extractWithDataDetector(lines: [String]) -> [DraftEvent] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let location = firstMatch(in: lines, patterns: [
            #"(?:場所|会場|教室)\s*(?:は|[:：])?\s*[「『]([^」』]+)[」』]"#,
            #"(?:場所|会場|教室)\s*(?:は|[:：])\s*([^。、\n]+?)(?:です|で行|にて|。|$)"#,
            #"(?i)(?:location|venue|where|place)\s*[:：]\s*(.+)$"#,
        ]) ?? ""
        let notes = lines.joined(separator: "\n")
        // Particles left dangling once the date is cut out of a Japanese sentence.
        let leftovers = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

        var events: [DraftEvent] = []
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = detector.firstMatch(in: line, range: range), let start = match.date else { continue }

            var title = (line as NSString).replacingCharacters(in: match.range, with: "").trimmingCharacters(in: leftovers)
            for particle in ["から", "より", "には", "に", "は", "の"] where title.hasPrefix(particle) {
                title = String(title.dropFirst(particle.count)).trimmingCharacters(in: leftovers)
                break
            }
            if title.isEmpty, index > 0 { title = lines[index - 1] }
            if title.isEmpty { title = "Event" }

            // A date with no clock time is an all-day event, not a made-up noon slot.
            let matched = (line as NSString).substring(with: match.range)
            let hasTime = matched.range(of: #"\d{1,2}\s*[:：時]|(?i)\d\s*[ap]\.?m\b|noon|午前|午後"#, options: .regularExpression) != nil
            var event = DraftEvent(title: title, start: start, end: start.addingTimeInterval(match.duration > 0 ? match.duration : 3600))
            if !hasTime {
                event.isAllDay = true
                event.start = Calendar.current.startOfDay(for: start)
                event.end = event.start
            }
            event.location = location
            event.notes = notes
            events.append(event)
        }
        return events.sorted { $0.start < $1.start }
    }

    private static func firstMatch(in lines: [String], patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for line in lines {
                if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let range = Range(match.range(at: 1), in: line) {
                    return line[range].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }
}

@Generable
private struct GeneratedSchedule {
    @Guide(description: "Every event found in the text. Empty when there are none.")
    var events: [GeneratedEvent]
}

@Generable
private struct GeneratedEvent {
    @Guide(description: "Short, specific event title")
    var title: String
    @Guide(description: "Start as yyyy-MM-dd'T'HH:mm only when the text states the event's own clock time; otherwise just yyyy-MM-dd")
    var start: String
    @Guide(description: "End in the same format as start, or an empty string when unknown")
    var end: String
    var allDay: Bool
    @Guide(description: "Place or meeting link, or an empty string")
    var location: String
    @Guide(description: "Other useful details, or an empty string")
    var notes: String
    @Guide(description: "True only for weekly timetable slots shown without a date")
    var repeatsWeekly: Bool
}
