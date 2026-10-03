import Foundation

enum ExtractionEngine: Equatable {
    case claude
    case custom(model: String)
    case appleIntelligence
    case basic

    var label: String {
        switch self {
        case .claude: "Claude"
        case .custom(let model): model
        case .appleIntelligence: "Apple Intelligence (on-device)"
        case .basic: "basic text detection (on-device)"
        }
    }
}

enum ExtractionError: LocalizedError {
    case noText
    case notConfigured(String)
    case api(String)
    case refused
    case truncated
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noText: "No readable text was found."
        case .notConfigured(let what): "\(what) Open Settings to finish setting it up."
        case .api(let message): "AI server error: \(message)"
        case .refused: "Claude declined to process this file."
        case .truncated: "There are too many events to read in one go. Try a smaller part of the schedule."
        case .badResponse: "The AI's answer could not be understood. Please try again."
        }
    }
}

enum ScheduleExtractor {
    typealias Result = (events: [DraftEvent], engine: ExtractionEngine)

    static func extract(from input: ScanInput, settings: ExtractionSettings) async throws -> Result {
        switch settings.engine {
        case .claude:
            return try await viaClaude(input, settings)
        case .custom:
            return try await viaServer(input, chunks: try await input.textChunks(), settings)
        case .onDevice:
            return try await onDevice(lines: try await input.textChunks().plainLines, settings)
        case .automatic:
            // Small, simple sources stay on the device; big ones go to a server if one is set up.
            let chunks = try await input.textChunks()
            let lines = chunks.plainLines
            let isSimple = input.pages.count == 1 && lines.count <= 150 && lines.joined().count <= 2500
            if isSimple, OnDeviceExtractor.isLanguageModelAvailable,
               let raw = try? await OnDeviceExtractor.extractWithLanguageModel(lines: lines, userContext: settings.userContext) {
                return (drafts(from: raw), .appleIntelligence)
            }
            if settings.hasCustomServer { return try await viaServer(input, chunks: chunks, settings) }
            if !settings.claudeKey.isEmpty { return try await viaClaude(input, settings) }
            if isSimple { return try await onDevice(lines: lines, settings) }
            throw ExtractionError.notConfigured("This schedule is too big to read on this device, and no AI server is set up for big ones.")
        }
    }

    private static func viaClaude(_ input: ScanInput, _ settings: ExtractionSettings) async throws -> Result {
        guard !settings.claudeKey.isEmpty else { throw ExtractionError.notConfigured("No Claude API key is set.") }
        let raw = try await ClaudeExtractor.extract(input: input, apiKey: settings.claudeKey, userContext: settings.userContext)
        return (drafts(from: raw), .claude)
    }

    private static func viaServer(_ input: ScanInput, chunks: [[TextChunk]], _ settings: ExtractionSettings) async throws -> Result {
        guard !settings.customBaseURL.isEmpty, !settings.customModel.isEmpty else {
            throw ExtractionError.notConfigured("The AI server address or model name is missing.")
        }
        guard settings.customSendsImages || chunks.contains(where: { !$0.isEmpty }) else { throw ExtractionError.noText }
        let raw = try await OpenAICompatibleExtractor.extract(
            layout: chunks.layoutDescription,
            images: settings.customSendsImages ? input.pageJPEGs : [],
            settings: settings)
        return (drafts(from: raw), .custom(model: settings.customModel))
    }

    private static func onDevice(lines: [String], _ settings: ExtractionSettings) async throws -> Result {
        guard !lines.isEmpty else { throw ExtractionError.noText }
        if OnDeviceExtractor.isLanguageModelAvailable,
           let raw = try? await OnDeviceExtractor.extractWithLanguageModel(lines: lines, userContext: settings.userContext) {
            return (drafts(from: raw), .appleIntelligence)
        }
        return (TimetableStore.fillInTimes(OnDeviceExtractor.extractWithDataDetector(lines: lines)), .basic)
    }

    private static func drafts(from raw: [RawEvent]) -> [DraftEvent] {
        TimetableStore.fillInTimes(raw.compactMap(DraftEvent.init(raw:))).sorted { $0.start < $1.start }
    }

    /// Shared instructions for every language model.
    static func instructions(userContext: String, now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, yyyy-MM-dd HH:mm"
        var text = """
        You turn schedules (timetables, chat messages, invitations, posters, tickets, emails, \
        handwritten notes) into calendar events.

        Right now it is \(formatter.string(from: now)) in the time zone \(TimeZone.current.identifier). \
        The user will add your output to their calendar, so every date must be concrete.

        For each distinct event:
        - title: short and specific, in the language used in the source. Name the thing itself \
        ("応用システム設計", "Dentist"), not the sentence it appeared in.
        - start / end: local time formatted as yyyy-MM-dd'T'HH:mm (24-hour). For all-day events use \
        yyyy-MM-dd and set allDay to true. If no end is given, leave end as an empty string.
        - Never invent a clock time. If the source gives a date but no time for the event itself, \
        make it an all-day event. The time a message was sent or posted is not the event's time.
        - Resolve relative dates ("tomorrow", "next Friday") against the current date above. When a \
        date has no year, pick the next occurrence on or after today.
        - Weekly timetables that show weekdays without dates (class or shift schedules): create one \
        event per slot on the next occurrence of that weekday and set repeatsWeekly to true. A class \
        that spans several consecutive periods is one event from the first period's start to the last \
        period's end. Otherwise repeatsWeekly is false.
        - location: where it is held (room, building, address or meeting link) if the source says so \
        anywhere, otherwise an empty string.
        - notes: a short description for the calendar entry: what the event is, plus every other \
        useful detail from the source (teacher, what to bring or prepare, instructions, booking \
        reference). Empty only when there is nothing to add.

        Only include events that are actually in the source. If there are none, return an empty list.
        """
        let context = userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            text += """


            About the user, in their own words:
            <user_context>
            \(context)
            </user_context>
            When the source covers many people, classes or groups (for example a whole-school timetable), \
            include only what applies to this user: their own class/row, plus the optional or elective \
            subjects they say they take. Leave out electives they did not mention.
            """
        }
        return text
    }

    /// Extra guidance for models that receive the text as positioned fragments.
    static let layoutGuide = """
    The source's text is given as fragments with positions: `y=… x=left-right | text`. Coordinates \
    run 0–1000, x from left to right and y from top to bottom, separately for each page. Fragments \
    with similar y are on the same row; a table cell is often two fragments stacked vertically \
    (for example a subject and, just below it, a teacher in brackets).

    To read a table, first find the header fragments (weekdays, period numbers, start and end times) \
    and the row labels, and note their x and y ranges. Text is centred inside its cell, so a cell \
    whose text sits between two adjacent header columns spans both of them; a cell centred across a \
    wide area spans all the columns it covers. Assign each cell to the row label nearest in y and \
    to the header columns its x range overlaps or sits between.
    """

    static let jsonGuide = """
    Reply with only a JSON object, no prose and no code fence, in exactly this shape:
    {"events":[{"title":"","start":"","end":"","allDay":false,"location":"","notes":"","repeatsWeekly":false}]}
    """
}
