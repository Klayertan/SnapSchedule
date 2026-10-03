import SwiftUI

struct EventRow: View {
    @Binding var draft: DraftEvent
    let conflict: String?
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            TextField("Title", text: $draft.title)
            Toggle("All day", isOn: $draft.isAllDay)
            DatePicker("Starts", selection: $draft.start, displayedComponents: components)
            DatePicker("Ends", selection: $draft.end, in: draft.start..., displayedComponents: components)
            TextField("Location", text: $draft.location)
            TextField("Notes", text: $draft.notes, axis: .vertical)
            Toggle("Repeats weekly", isOn: $draft.repeatsWeekly)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    draft.isSelected.toggle()
                } label: {
                    Image(systemName: draft.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(draft.isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(draft.isSelected ? "Included" : "Not included")

                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.title)
                        .font(.headline)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !draft.location.isEmpty {
                        Label(draft.location, systemImage: "mappin.and.ellipse")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let matched = draft.matchedClass {
                        Label("Time from your timetable: \(matched)", systemImage: "clock.badge.checkmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let conflict {
                        Label("Overlaps “\(conflict)”", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .opacity(draft.isSelected ? 1 : 0.5)
        }
        // Moving the start keeps the event's length.
        .onChange(of: draft.start) { old, new in
            draft.end = draft.end.addingTimeInterval(new.timeIntervalSince(old))
        }
    }

    private var components: DatePickerComponents {
        draft.isAllDay ? .date : [.date, .hourAndMinute]
    }

    private var summary: String {
        var text: String
        if draft.isAllDay {
            text = draft.start.formatted(date: .abbreviated, time: .omitted) + " · All day"
        } else if draft.end > draft.start {
            text = (draft.start..<draft.end).formatted(date: .abbreviated, time: .shortened)
        } else {
            text = draft.start.formatted(date: .abbreviated, time: .shortened)
        }
        if draft.repeatsWeekly { text += " · Weekly" }
        return text
    }
}
