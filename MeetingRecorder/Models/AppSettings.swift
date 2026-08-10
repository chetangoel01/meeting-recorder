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
        static let obsidianExportEnabled = "obsidianExportEnabled"
        static let obsidianExportPath = "obsidianExportPath"
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

    @Published var obsidianExportEnabled: Bool {
        didSet { defaults.set(obsidianExportEnabled, forKey: Key.obsidianExportEnabled) }
    }

    @Published var obsidianExportPath: String {
        didSet { defaults.set(obsidianExportPath, forKey: Key.obsidianExportPath) }
    }

    static let defaultObsidianExportPath = NSString(
        string: "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault/Meetings"
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
        obsidianExportEnabled = defaults.object(forKey: Key.obsidianExportEnabled) as? Bool ?? false
        obsidianExportPath = defaults.string(forKey: Key.obsidianExportPath) ?? ""
    }
}
