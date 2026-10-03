import Foundation

/// An event found in a picture, editable before it is saved to the calendar.
struct DraftEvent: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    var location = ""
    var notes = ""
    var repeatsWeekly = false
    var isSelected = true
    /// Set when the time came from the user's saved timetable rather than from the picture.
    var matchedClass: String?
}

/// The wire format both language models are asked to produce.
struct RawEvent: Codable {
    var title: String
    /// `yyyy-MM-dd'T'HH:mm` in the user's time zone, or `yyyy-MM-dd` for all-day events.
    var start: String
    /// Same format as `start`; empty when the picture gives no end.
    var end: String
    var allDay: Bool
    var location: String
    var notes: String
    var repeatsWeekly: Bool
}

extension RawEvent {
    /// Models without schema enforcement sometimes leave fields out or send null.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        start = (try? container.decode(String.self, forKey: .start)) ?? ""
        end = (try? container.decode(String.self, forKey: .end)) ?? ""
        allDay = (try? container.decode(Bool.self, forKey: .allDay)) ?? false
        location = (try? container.decode(String.self, forKey: .location)) ?? ""
        notes = (try? container.decode(String.self, forKey: .notes)) ?? ""
        repeatsWeekly = (try? container.decode(Bool.self, forKey: .repeatsWeekly)) ?? false
    }
}

struct RawSchedule: Codable {
    var events: [RawEvent]
}

extension DraftEvent {
    init?(raw: RawEvent) {
        guard let start = Self.parse(raw.start) else { return nil }
        let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // A start with no clock time is an all-day event whatever the flag says.
        let allDay = raw.allDay || !raw.start.contains(":")
        var end = Self.parse(raw.end) ?? start
        if end <= start {
            end = allDay ? start : start.addingTimeInterval(3600)
        }
        self.init(
            title: title.isEmpty ? "Untitled event" : title,
            start: start,
            end: end,
            isAllDay: allDay,
            location: raw.location,
            notes: raw.notes,
            repeatsWeekly: raw.repeatsWeekly
        )
    }

    private static func parse(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string.trimmingCharacters(in: .whitespaces)) {
                return date
            }
        }
        return nil
    }
}
