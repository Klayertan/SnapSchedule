import Foundation

enum EngineChoice: String, CaseIterable, Identifiable {
    case automatic, onDevice, custom, claude

    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .onDevice: "On this device only"
        case .custom: "AI server (OpenAI-compatible)"
        case .claude: "Claude"
        }
    }
}

enum SettingsKey {
    static let engine = "engine"
    static let userContext = "userContext"
    static let customBaseURL = "customBaseURL"
    static let customModel = "customModel"
    static let customSendsImages = "customSendsImages"

    static let defaultBaseURL = "https://api.ai.sakura.ad.jp/v1"
    static let defaultModel = "gpt-oss-120b"
}

/// A snapshot of everything the extractors need, read once per scan.
struct ExtractionSettings {
    var engine: EngineChoice
    var userContext: String
    var customBaseURL: String
    var customModel: String
    var customSendsImages: Bool
    var customKey: String
    var claudeKey: String

    /// Whether the user has pointed the app at a server of their own or entered a key for it.
    var hasCustomServer: Bool {
        !customBaseURL.isEmpty && !customModel.isEmpty && (!customKey.isEmpty || customBaseURL != SettingsKey.defaultBaseURL)
    }

    static var current: ExtractionSettings {
        let defaults = UserDefaults.standard
        return ExtractionSettings(
            engine: EngineChoice(rawValue: defaults.string(forKey: SettingsKey.engine) ?? "") ?? .automatic,
            userContext: defaults.string(forKey: SettingsKey.userContext) ?? "",
            customBaseURL: defaults.string(forKey: SettingsKey.customBaseURL) ?? SettingsKey.defaultBaseURL,
            customModel: defaults.string(forKey: SettingsKey.customModel) ?? SettingsKey.defaultModel,
            customSendsImages: defaults.bool(forKey: SettingsKey.customSendsImages),
            customKey: KeychainStore.customKey ?? "",
            claudeKey: KeychainStore.apiKey ?? ""
        )
    }
}
