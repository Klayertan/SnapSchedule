import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = AppModel()
    @State private var calendar = CalendarService()
    @State private var photoItem: PhotosPickerItem?
    @State private var calendarID: String?
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var isDropTargeted = false
    @State private var endsRepeats = true
    @State private var repeatUntil = Calendar.current.date(byAdding: .month, value: 5, to: .now) ?? .now
    @AppStorage(SettingsKey.userContext) private var userContext = ""

    var body: some View {
        NavigationStack {
            Group {
                if !model.isReviewing {
                    importView
                } else {
                    reviewView
                }
            }
            .navigationTitle("SnapSchedule")
            .toolbar {
                if model.isReviewing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("New Picture", systemImage: "plus") { model.reset() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
        }
        .onDrop(of: [.image, .pdf, .fileURL], isTargeted: $isDropTargeted) { model.load(providers: $0) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image, .pdf]) { result in
            if case .success(let url) = result { model.load(url: url) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    model.load(data: data)
                } else {
                    model.errorMessage = "That photo could not be loaded."
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView(onAddTimetable: model.showTimetable) }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            if calendar.status == .notDetermined {
                await calendar.requestAccess()
            } else {
                calendar.refresh()
            }
            calendarID = calendar.defaultCalendarID
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    // MARK: Import

    private var importView: some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Add a screenshot, photo or PDF of a schedule")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Timetables, chat messages, invitations, tickets — events are read from it and added to your calendar after you review them.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showImporter = true
                } label: {
                    Label("Choose a File", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                #if os(macOS)
                Button {
                    model.pasteFromClipboard()
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("v", modifiers: .command)
                #else
                PasteButton(supportedContentTypes: [.image]) { model.load(providers: $0) }
                #endif
            }
            .controlSize(.large)
            .frame(maxWidth: 320)

            VStack(alignment: .leading, spacing: 6) {
                Text("About you (optional)")
                    .font(.subheadline.weight(.semibold))
                TextField("e.g. I'm in class 5S. My electives: 日本文化学, 地域学. Room: …", text: $userContext, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                Text("Used to pick out your own classes from a shared timetable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 420)

            #if os(macOS)
            Text("You can also drag a picture or PDF here, or press ⌃⇧⌘4 to screenshot to the clipboard and then ⌘V.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            #endif
        }
        .padding(32)
        .frame(maxWidth: 520, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .padding(12)
            }
        }
    }

    // MARK: Review

    private var reviewView: some View {
        Form {
            if let input = model.input {
                Section {
                    Image(decorative: input.preview, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            if model.isAnalyzing {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading your schedule…")
                    }
                }
            } else if let count = model.savedCount {
                Section {
                    Label("Added \(count) event\(count == 1 ? "" : "s") to your calendar", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Scan Another Picture") { model.reset() }
                }
            } else if model.drafts.isEmpty {
                Section {
                    Text("No events were found.")
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await model.analyze() } }
                }
            } else {
                Section {
                    ForEach($model.drafts) { $draft in
                        EventRow(draft: $draft, conflict: calendar.conflict(for: draft))
                    }
                    .onDelete { model.drafts.remove(atOffsets: $0) }
                } header: {
                    Text("Found \(model.drafts.count) event\(model.drafts.count == 1 ? "" : "s")")
                } footer: {
                    if model.engine == .basic {
                        Text("Read with basic text detection, which only spots dates and is often wrong. \(OnDeviceExtractor.languageModelProblem ?? "") For timetables and anything complex, choose an AI in Settings.")
                    } else if let engine = model.engine {
                        Text("Read with \(engine.label). Check the details before adding.")
                    }
                }

                Section {
                    if calendar.hasAccess {
                        Picker("Calendar", selection: $calendarID) {
                            ForEach(calendar.calendars, id: \.calendarIdentifier) { item in
                                Text(item.title).tag(Optional(item.calendarIdentifier))
                            }
                        }
                    }
                    if model.selectedDrafts.contains(where: \.repeatsWeekly) {
                        Toggle("Stop weekly repeats on a date", isOn: $endsRepeats)
                        if endsRepeats {
                            DatePicker("Repeat until", selection: $repeatUntil, in: Date.now..., displayedComponents: .date)
                        }
                    }
                    Button(action: addToCalendar) {
                        Text("Add \(model.selectedDrafts.count) to Calendar")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.selectedDrafts.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addToCalendar() {
        Task {
            if !calendar.hasAccess {
                await calendar.requestAccess()
                calendarID = calendarID ?? calendar.defaultCalendarID
            }
            guard calendar.hasAccess else {
                model.errorMessage = "SnapSchedule needs full calendar access. Turn it on in Settings › Privacy & Security › Calendars."
                return
            }
            do {
                model.savedCount = try calendar.save(model.selectedDrafts, calendarID: calendarID, repeatUntil: endsRepeats ? repeatUntil : nil)
                TimetableStore.remember(model.selectedDrafts)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    ContentView()
}
