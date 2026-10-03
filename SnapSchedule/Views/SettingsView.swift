import SwiftUI

struct SettingsView: View {
    var onAddTimetable: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.engine) private var engine = EngineChoice.automatic
    @AppStorage(SettingsKey.customBaseURL) private var customBaseURL = SettingsKey.defaultBaseURL
    @AppStorage(SettingsKey.customModel) private var customModel = SettingsKey.defaultModel
    @AppStorage(SettingsKey.customSendsImages) private var customSendsImages = false
    @AppStorage(SettingsKey.userContext) private var userContext = ""
    @State private var customKey = KeychainStore.customKey ?? ""
    @State private var claudeKey = KeychainStore.apiKey ?? ""
    @State private var timetable = TimetableStore.load()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Read schedules with", selection: $engine) {
                        ForEach(EngineChoice.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text(engineHelp)
                }

                if engine == .custom || engine == .automatic {
                    Section {
                        TextField("Server address", text: $customBaseURL, prompt: Text(SettingsKey.defaultBaseURL))
                            .autocorrectionDisabled()
                        TextField("Model name", text: $customModel, prompt: Text(SettingsKey.defaultModel))
                            .autocorrectionDisabled()
                        SecureField("API key (leave empty if the server needs none)", text: $customKey)
                        Toggle("Model can see images", isOn: $customSendsImages)
                    } header: {
                        Text(engine == .automatic ? "AI server for big schedules (optional)" : "AI server")
                    } footer: {
                        Text("Works with Sakura AI Engine, or a model on your own computer (for example Ollama at http://your-mac.local:11434/v1). Leave “Model can see images” off for text-only models; turn it on for a vision model.")
                    }
                }
                if engine == .claude || engine == .automatic {
                    Section {
                        SecureField("Claude API key", text: $claudeKey)
                        Link("Get an API key", destination: URL(string: "https://platform.claude.com/settings/keys")!)
                    } header: {
                        Text(engine == .automatic ? "Claude for big schedules (optional, paid)" : "Claude")
                    }
                }

                Section {
                    ForEach($timetable) { $entry in
                        DisclosureGroup {
                            TextField("Class", text: $entry.title)
                            Picker("Day", selection: $entry.weekday) {
                                ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                            }
                            DatePicker("Starts", selection: clock($entry.startMinutes), displayedComponents: .hourAndMinute)
                            DatePicker("Ends", selection: clock($entry.endMinutes), displayedComponents: .hourAndMinute)
                            TextField("Location", text: $entry.location)
                            TextField("Notes", text: $entry.notes)
                            Button("Remove Class", role: .destructive) {
                                timetable.removeAll { $0.id == entry.id }
                            }
                        } label: {
                            Text(entry.summary)
                        }
                    }
                    Button("Add Class") {
                        timetable.append(TimetableEntry(title: "", weekday: 2, startMinutes: 9 * 60, endMinutes: 10 * 60 + 30))
                    }
                    Button("Add Timetable to Calendar…") {
                        save()
                        onAddTimetable()
                        dismiss()
                    }
                    .disabled(timetable.isEmpty)
                } header: {
                    Text("My timetable")
                } footer: {
                    Text("When a message mentions one of these classes on its usual day without a time, the app fills in the time and place from here. Weekly events you add to your calendar are remembered here automatically.")
                }

                Section {
                    TextField("e.g. I'm in class 5S. My electives: …", text: $userContext, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("About you")
                } footer: {
                    Text("Sent along with each schedule so the AI can pick out what applies to you.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 640)
        #else
        .textInputAutocapitalization(.never)
        #endif
    }

    private func save() {
        KeychainStore.customKey = customKey
        KeychainStore.apiKey = claudeKey
        TimetableStore.save(timetable)
    }

    /// Edits minutes-since-midnight through a time picker.
    private func clock(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(byAdding: .minute, value: minutes.wrappedValue, to: Calendar.current.startOfDay(for: .now)) ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    private var engineHelp: String {
        switch engine {
        case .automatic:
            "Simple pictures such as messages are read on this device, free and private. Big or complex ones (whole timetables, multi-page PDFs) are sent to the AI server below, if you set one up."
        case .onDevice:
            "Free and private: nothing leaves this device. Uses Apple Intelligence where available, otherwise basic date detection. Good for simple messages, not for timetables."
        case .custom:
            "Sends the schedule's text (and optionally the pages) to a server you choose, such as Sakura AI Engine or a model you host yourself. Keys are stored in your keychain."
        case .claude:
            "Sends the picture or PDF to Anthropic. Best on dense timetables and handwriting. Billed to your Anthropic account."
        }
    }
}
