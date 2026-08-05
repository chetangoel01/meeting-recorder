import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let launchAtLogin = "launchAtLogin"
        static let calendarBackup = "calendarBackup"
        static let keepRecordings = "keepRecordings"
        static let transcriptionModel = "transcriptionModel"
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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? true
        calendarBackup = defaults.object(forKey: Key.calendarBackup) as? Bool ?? true
        keepRecordings = defaults.object(forKey: Key.keepRecordings) as? Bool ?? false
        transcriptionModel = defaults.string(forKey: Key.transcriptionModel) ?? "openai/whisper-large-v3"
    }
}
