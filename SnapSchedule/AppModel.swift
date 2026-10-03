import Foundation
import Observation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class AppModel {
    private(set) var input: ScanInput?
    var drafts: [DraftEvent] = []
    private(set) var isAnalyzing = false
    private(set) var engine: ExtractionEngine?
    var savedCount: Int?
    var errorMessage: String?

    var selectedDrafts: [DraftEvent] { drafts.filter(\.isSelected) }
    var isReviewing: Bool { input != nil || !drafts.isEmpty || savedCount != nil }

    /// Puts the saved weekly timetable on the review screen so it can be added to the calendar.
    func showTimetable() {
        reset()
        drafts = TimetableStore.load().map { $0.draft() }
    }

    func reset() {
        input = nil
        drafts = []
        engine = nil
        savedCount = nil
    }

    func load(data: Data) {
        guard let loaded = ScanInput(data: data) else {
            errorMessage = "That file could not be read as a picture or PDF."
            return
        }
        reset()
        input = loaded
        Task { await analyze() }
    }

    func load(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "That file could not be opened."
            return
        }
        load(data: data)
    }

    /// Handles drag-and-drop and paste. Returns whether a usable item was found.
    @discardableResult
    func load(providers: [NSItemProvider]) -> Bool {
        for type in [UTType.image, .pdf] {
            guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else { continue }
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in self.load(data: data) }
            }
            return true
        }
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in self.load(url: url) }
            }
            return true
        }
        return false
    }

    #if os(macOS)
    /// Reads a screenshot, copied image or copied image file straight from the clipboard.
    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .pdf) {
            load(data: data)
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  let url = urls.first {
            load(url: url)
        } else {
            errorMessage = "There is no picture on the clipboard. Press ⌃⇧⌘4 to take a screenshot to the clipboard, then paste."
        }
    }
    #endif

    func analyze() async {
        guard let input, !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let result = try await ScheduleExtractor.extract(from: input, settings: .current)
            drafts = result.events
            engine = result.engine
        } catch {
            drafts = []
            errorMessage = error.localizedDescription
        }
    }
}
