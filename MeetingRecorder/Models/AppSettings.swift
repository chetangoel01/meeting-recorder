import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let launchAtLogin = "launchAtLogin"
        static let calendarBackup = "calendarBackup"
        static let keepRecordings = "keepRecordings"
        static let transcriptionModel = "transcriptionModel"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let microphoneID = "microphoneID"
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

    // AVCaptureDevice uniqueID of the microphone to record from; empty means
    // the system default input. A device that is no longer attached falls
    // back to the default at recording time rather than failing the recording.
    @Published var microphoneID: String {
        didSet { defaults.set(microphoneID, forKey: Key.microphoneID) }
    }

    @Published var transcriptionModel: String {
        didSet { defaults.set(transcriptionModel, forKey: Key.transcriptionModel) }
    }

    // ISO-639-1 code sent as Whisper's language hint; empty means auto-detect.
    @Published var transcriptionLanguage: String {
        didSet { defaults.set(transcriptionLanguage, forKey: Key.transcriptionLanguage) }
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

    static let transcriptionLanguages: [(code: String, name: String)] = [
        ("", "Auto-detect"),
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("ru", "Russian"),
        ("hi", "Hindi"), ("ur", "Urdu"), ("ar", "Arabic"), ("zh", "Chinese"),
        ("ja", "Japanese"), ("ko", "Korean"), ("tr", "Turkish"), ("pl", "Polish"),
    ]

    static let defaultObsidianVaultPath = NSString(
        string: "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Vault"
    ).expandingTildeInPath

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? true
        calendarBackup = defaults.object(forKey: Key.calendarBackup) as? Bool ?? true
        keepRecordings = defaults.object(forKey: Key.keepRecordings) as? Bool ?? false
        microphoneID = defaults.string(forKey: Key.microphoneID) ?? ""
        transcriptionModel = defaults.string(forKey: Key.transcriptionModel) ?? "openai/whisper-large-v3"
        transcriptionLanguage = defaults.string(forKey: Key.transcriptionLanguage) ?? "en"
        analysisEnabled = defaults.object(forKey: Key.analysisEnabled) as? Bool ?? true
        analysisModel = defaults.string(forKey: Key.analysisModel) ?? "deepseek/deepseek-v4-pro"
        analysisPrompt = defaults.string(forKey: Key.analysisPrompt) ?? AnalysisClient.defaultInstructions
        obsidianVaultPath = defaults.string(forKey: Key.obsidianVaultPath) ?? ""
    }
}
