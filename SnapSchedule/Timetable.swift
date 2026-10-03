import Foundation

/// One weekly class the user attends. Used to fill in times that a message leaves out.
struct TimetableEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    /// 1 = Sunday … 7 = Saturday, as in `Calendar`.
    var weekday: Int
    var startMinutes: Int
    var endMinutes: Int
    var location = ""
    var notes = ""

    var summary: String {
        let day = Calendar.current.shortWeekdaySymbols[(weekday - 1) % 7]
        return "\(day) \(Self.clock(startMinutes))–\(Self.clock(endMinutes))  \(title)"
    }

    private static func clock(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// The name without decorations such as "[選]", for matching against event titles.
    var coreName: String {
        title.replacingOccurrences(of: #"[\[［【(（][^\]］】)）]*[\]］】)）]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    func date(on day: Date, minutes: Int) -> Date {
        Calendar.current.date(byAdding: .minute, value: minutes, to: Calendar.current.startOfDay(for: day)) ?? day
    }

    /// A weekly repeating draft starting on the next day this class takes place.
    func draft(from now: Date = .now) -> DraftEvent {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let offset = (weekday - calendar.component(.weekday, from: today) + 7) % 7
        let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
        return DraftEvent(title: title, start: date(on: day, minutes: startMinutes), end: date(on: day, minutes: endMinutes),
                          location: location, notes: notes, repeatsWeekly: true)
    }
}

enum TimetableStore {
    private static let key = "timetable"

    static func load() -> [TimetableEntry] {
        guard let json = UserDefaults.standard.string(forKey: key),
              let entries = try? JSONDecoder().decode([TimetableEntry].self, from: Data(json.utf8)) else { return [] }
        return entries.sorted { ($0.weekday, $0.startMinutes) < ($1.weekday, $1.startMinutes) }
    }

    static func save(_ entries: [TimetableEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: key)
    }

    /// Remembers weekly events the user added to their calendar as part of their timetable.
    static func remember(_ drafts: [DraftEvent]) {
        var entries = load()
        let calendar = Calendar.current
        for draft in drafts where draft.repeatsWeekly && !draft.isAllDay {
            let weekday = calendar.component(.weekday, from: draft.start)
            let start = calendar.component(.hour, from: draft.start) * 60 + calendar.component(.minute, from: draft.start)
            guard !entries.contains(where: { $0.weekday == weekday && $0.startMinutes == start && $0.title == draft.title }) else { continue }
            let end = start + max(Int(draft.end.timeIntervalSince(draft.start) / 60), 0)
            entries.append(TimetableEntry(title: draft.title, weekday: weekday, startMinutes: start, endMinutes: end,
                                          location: draft.location, notes: draft.notes))
        }
        save(entries)
    }

    /// Gives an all-day event the time and place of the class it is about, when the weekday fits.
    static func fillInTimes(_ drafts: [DraftEvent]) -> [DraftEvent] {
        let entries = load()
        guard !entries.isEmpty else { return drafts }
        return drafts.map { draft in
            guard draft.isAllDay, !draft.repeatsWeekly else { return draft }
            let weekday = Calendar.current.component(.weekday, from: draft.start)
            let match = entries
                .filter { $0.weekday == weekday && !$0.coreName.isEmpty && draft.title.localizedCaseInsensitiveContains($0.coreName) }
                .max { $0.coreName.count < $1.coreName.count }
            guard let match else { return draft }
            var filled = draft
            filled.isAllDay = false
            filled.end = match.date(on: draft.start, minutes: match.endMinutes)
            filled.start = match.date(on: draft.start, minutes: match.startMinutes)
            if filled.location.isEmpty { filled.location = match.location }
            filled.matchedClass = match.title
            return filled
        }
    }
}
