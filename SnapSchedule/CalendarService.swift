import EventKit
import Foundation
import Observation

/// Thin wrapper around EventKit: permission, calendar list, conflict lookup and saving.
@MainActor
@Observable
final class CalendarService {
    private let store = EKEventStore()
    private(set) var status = EKEventStore.authorizationStatus(for: .event)
    private(set) var calendars: [EKCalendar] = []

    var hasAccess: Bool { status == .fullAccess }
    var defaultCalendarID: String? { store.defaultCalendarForNewEvents?.calendarIdentifier }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        refresh()
    }

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        calendars = hasAccess
            ? store.calendars(for: .event)
                .filter(\.allowsContentModifications)
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            : []
    }

    /// Title of an existing timed event that overlaps the draft, if any.
    func conflict(for draft: DraftEvent) -> String? {
        guard hasAccess, !draft.isAllDay, draft.end > draft.start else { return nil }
        let predicate = store.predicateForEvents(withStart: draft.start, end: draft.end, calendars: nil)
        return store.events(matching: predicate).first { !$0.isAllDay }?.title
    }

    @discardableResult
    func save(_ drafts: [DraftEvent], calendarID: String?, repeatUntil: Date?) throws -> Int {
        let calendar = calendars.first { $0.calendarIdentifier == calendarID } ?? store.defaultCalendarForNewEvents
        for draft in drafts {
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = draft.title
            event.startDate = draft.start
            event.endDate = draft.end
            event.isAllDay = draft.isAllDay
            event.location = draft.location.isEmpty ? nil : draft.location
            event.notes = draft.notes.isEmpty ? nil : draft.notes
            if draft.repeatsWeekly {
                event.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: repeatUntil.map(EKRecurrenceEnd.init(end:))))
            }
            try store.save(event, span: .thisEvent, commit: false)
        }
        try store.commit()
        return drafts.count
    }
}
