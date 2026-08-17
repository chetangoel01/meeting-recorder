import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let launchAtLogin = "launchAtLogin"
        static let calendarBackup = "calendarBackup"
        static let keepRecordings = "keepRecordings"
        static let transcriptionModel = "transcriptionModel"
        static let analysisEnabled = "analysisEnabled"
        static let analysisModel = "analysisModel"
        static let analysisPrompt = "analysisPrompt"
        static let obsidianVaultPath = "obsidianVaultPath"
    }

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    @Published var calendarBackup: Bool {
        didSet { defaults.set(calendarBackup, forKey: Key.calendarBackup) }
    }

    @Published var keepRecordings: Bool {
        didSet { defaults.set(keepRecordings, forKey: Key.keepRecordings) }
    }

    @Published var transcriptionModel: String {
        didSet { defaults.set(transcriptionModel, forKey: Key.transcriptionModel) }
    }

    @Published var analysisEnabled: Bool {
        didSet { defaults.set(analysisEnabled, forKey: Key.analysisEnabled) }
    }

    @Published var analysisModel: String {
        didSet { defaults.set(analysisModel, forKey: Key.analysisModel) }
    }

    @Published var analysisPrompt: String {
        didSet { defaults.set(analysisPrompt, forKey: Key.analysisPrompt) }
    }

    @Published var obsidianVaultPath: String {
        didSet { defaults.set(obsidianVaultPath, forKey: Key.obsidianVaultPath) }
    }

    static let defaultObsidianVaultPath = NSString(
        string: "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault"
    ).expandingTildeInPath

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? true
        calendarBackup = defaults.object(forKey: Key.calendarBackup) as? Bool ?? true
        keepRecordings = defaults.object(forKey: Key.keepRecordings) as? Bool ?? false
        transcriptionModel = defaults.string(forKey: Key.transcriptionModel) ?? "openai/whisper-large-v3"
        analysisEnabled = defaults.object(forKey: Key.analysisEnabled) as? Bool ?? true
        analysisModel = defaults.string(forKey: Key.analysisModel) ?? "deepseek/deepseek-v4-pro"
        analysisPrompt = defaults.string(forKey: Key.analysisPrompt) ?? AnalysisClient.defaultInstructions
        obsidianVaultPath = defaults.string(forKey: Key.obsidianVaultPath) ?? ""
    }
}
