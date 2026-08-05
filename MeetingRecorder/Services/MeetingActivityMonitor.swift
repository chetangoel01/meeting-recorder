import AppKit
import CoreAudio
import Foundation

struct MeetingAppClassifier {
    private static let nativeClients: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.webex.meetingmanager": "Webex",
        "com.apple.FaceTime": "FaceTime",
    ]

    private static let knownBrowsers: [String: String] = [
        "company.thebrowser.Browser": "Arc",
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.canary": "Chrome Canary",
        "org.mozilla.firefox": "Firefox",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave",
        "com.operasoftware.Opera": "Opera",
        "org.chromium.Chromium": "Chromium",
    ]

    static func nativeClientName(bundleIdentifier: String) -> String? {
        nativeClients.first { key, _ in
            bundleIdentifier == key || bundleIdentifier.hasPrefix("\(key).")
        }?.value
    }

    static func browserName(bundleIdentifier: String) -> String? {
        knownBrowsers.first { key, _ in
            bundleIdentifier == key || bundleIdentifier.hasPrefix("\(key).")
        }?.value
    }

    static func isBrowser(bundleIdentifier: String, bundleURL: URL?) -> Bool {
        if browserName(bundleIdentifier: bundleIdentifier) != nil { return true }
        guard var candidateURL = bundleURL else { return false }

        while candidateURL.pathComponents.count > 1 {
            if candidateURL.pathExtension == "app",
               let bundle = Bundle(url: candidateURL),
               let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] {
                let schemes = urlTypes
                    .compactMap { $0["CFBundleURLSchemes"] as? [String] }
                    .flatMap { $0 }
                    .map { $0.lowercased() }
                if schemes.contains("http") && schemes.contains("https") {
                    return true
                }
            }
            candidateURL.deleteLastPathComponent()
        }
        return false
    }
}

final class MeetingActivityMonitor: @unchecked Sendable {
    typealias Handler = @Sendable (MeetingCandidate) -> Void

    private struct ProcessState {
        let candidate: MeetingCandidate
        let runningInput: Bool
        let runningOutput: Bool
    }

    private let queue = DispatchQueue(label: "MeetingRecorder.MeetingActivityMonitor")
    private var timer: DispatchSourceTimer?
    private var activeIdentifiers: Set<String> = []
    private var suppressedIdentifiers: Set<String> = []
    private var outputStreaks: [String: Int] = [:]
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(150))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.activeIdentifiers.removeAll()
            self?.outputStreaks.removeAll()
        }
    }

    func suppress(candidateID: String) {
        queue.async { [weak self] in
            self?.suppressedIdentifiers.insert(candidateID)
        }
    }

    private func poll() {
        let states = Self.currentMeetingProcesses()
        var currentlyActive: Set<String> = []

        for state in states {
            let id = state.candidate.id
            let isBrowser = state.candidate.trigger == .browser
            if state.runningOutput {
                outputStreaks[id, default: 0] += 1
            } else {
                outputStreaks[id] = 0
            }

            let active = state.runningInput || (!isBrowser && outputStreaks[id, default: 0] >= 3)
            guard active else { continue }
            currentlyActive.insert(id)

            if !activeIdentifiers.contains(id), !suppressedIdentifiers.contains(id) {
                handler(state.candidate)
            }
        }

        let ended = activeIdentifiers.subtracting(currentlyActive)
        suppressedIdentifiers.subtract(ended)
        for id in ended { outputStreaks[id] = nil }
        activeIdentifiers = currentlyActive
    }

    private static func currentMeetingProcesses() -> [ProcessState] {
        processObjectIDs().compactMap { objectID in
            guard let pid = processID(for: objectID),
                  let app = NSRunningApplication(processIdentifier: pid),
                  let bundleIdentifier = app.bundleIdentifier
            else {
                return nil
            }

            let nativeName = MeetingAppClassifier.nativeClientName(bundleIdentifier: bundleIdentifier)
            let browser = MeetingAppClassifier.isBrowser(
                bundleIdentifier: bundleIdentifier,
                bundleURL: app.bundleURL
            )
            guard nativeName != nil || browser else { return nil }

            let name = nativeName
                ?? MeetingAppClassifier.browserName(bundleIdentifier: bundleIdentifier)
                ?? app.localizedName
                ?? "Web browser"
            let trigger: MeetingCandidate.Trigger = browser ? .browser : .nativeApp
            let candidate = MeetingCandidate(
                id: "\(bundleIdentifier):\(pid)",
                appName: name,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: pid,
                trigger: trigger
            )

            return ProcessState(
                candidate: candidate,
                runningInput: booleanProperty(
                    kAudioProcessPropertyIsRunningInput,
                    objectID: objectID
                ),
                runningOutput: booleanProperty(
                    kAudioProcessPropertyIsRunningOutput,
                    objectID: objectID
                )
            )
        }
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else {
            return []
        }
        return ids
    }

    private static func processID(for objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr else {
            return nil
        }
        return pid
    }

    private static func booleanProperty(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }
}
