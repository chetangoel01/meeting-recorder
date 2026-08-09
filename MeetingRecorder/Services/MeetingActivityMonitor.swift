import AppKit
import CoreAudio
import Foundation

struct MeetingAppClassifier {
    struct NativeIdentity: Equatable {
        let bundleIdentifier: String
        let name: String
    }

    struct BrowserIdentity: Equatable {
        let bundleIdentifier: String
        let name: String
    }

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
        nativeIdentity(bundleIdentifier: bundleIdentifier)?.name
    }

    static func nativeIdentity(bundleIdentifier: String) -> NativeIdentity? {
        nativeClients
            .filter { key, _ in
                bundleIdentifier == key || bundleIdentifier.hasPrefix("\(key).")
            }
            .max { left, right in left.key.count < right.key.count }
            .map { NativeIdentity(bundleIdentifier: $0.key, name: $0.value) }
    }

    static func browserName(bundleIdentifier: String) -> String? {
        knownBrowserIdentity(bundleIdentifier: bundleIdentifier)?.name
    }

    static func isBrowser(bundleIdentifier: String, bundleURL: URL?) -> Bool {
        browserIdentity(bundleIdentifier: bundleIdentifier, bundleURL: bundleURL) != nil
    }

    static func browserIdentity(bundleIdentifier: String, bundleURL: URL?) -> BrowserIdentity? {
        if let known = knownBrowserIdentity(bundleIdentifier: bundleIdentifier) { return known }
        guard var candidateURL = bundleURL else { return nil }

        while candidateURL.pathComponents.count > 1 {
            if candidateURL.pathExtension == "app",
               let bundle = Bundle(url: candidateURL),
               let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] {
                let schemes = urlTypes
                    .compactMap { $0["CFBundleURLSchemes"] as? [String] }
                    .flatMap { $0 }
                    .map { $0.lowercased() }
                if schemes.contains("http") && schemes.contains("https") {
                    let hostBundleIdentifier = bundle.bundleIdentifier ?? bundleIdentifier
                    let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? "Web browser"
                    return BrowserIdentity(bundleIdentifier: hostBundleIdentifier, name: name)
                }
            }
            candidateURL.deleteLastPathComponent()
        }
        return nil
    }

    private static func knownBrowserIdentity(bundleIdentifier: String) -> BrowserIdentity? {
        knownBrowsers
            .filter { key, _ in
                bundleIdentifier == key || bundleIdentifier.hasPrefix("\(key).")
            }
            .max { left, right in left.key.count < right.key.count }
            .map { BrowserIdentity(bundleIdentifier: $0.key, name: $0.value) }
    }
}

struct MeetingActivityRule {
    static func isActive(
        trigger: MeetingCandidate.Trigger,
        runningInput: Bool,
        consecutiveOutputSamples: Int
    ) -> Bool {
        switch trigger {
        case .browser:
            return runningInput && consecutiveOutputSamples >= 2
        case .nativeApp:
            return runningInput || consecutiveOutputSamples >= 3
        case .calendar, .manual:
            return false
        }
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
            if state.runningOutput {
                outputStreaks[id, default: 0] += 1
            } else {
                outputStreaks[id] = 0
            }

            let active = MeetingActivityRule.isActive(
                trigger: state.candidate.trigger,
                runningInput: state.runningInput,
                consecutiveOutputSamples: outputStreaks[id, default: 0]
            )
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
        var states: [String: ProcessState] = [:]

        for objectID in processObjectIDs() {
            guard let pid = processID(for: objectID) else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            guard let bundleIdentifier = stringProperty(
                kAudioProcessPropertyBundleID,
                objectID: objectID
            ) ?? app?.bundleIdentifier else { continue }

            let native = MeetingAppClassifier.nativeIdentity(bundleIdentifier: bundleIdentifier)
            let browser = MeetingAppClassifier.browserIdentity(
                bundleIdentifier: bundleIdentifier,
                bundleURL: app?.bundleURL
            )
            guard native != nil || browser != nil else { continue }

            let canonicalBundleIdentifier = browser?.bundleIdentifier
                ?? native?.bundleIdentifier
                ?? bundleIdentifier
            let hostApp = runningHost(bundleIdentifier: canonicalBundleIdentifier) ?? app
            let name = native?.name ?? browser?.name ?? app?.localizedName ?? "Meeting app"
            let trigger: MeetingCandidate.Trigger = browser == nil ? .nativeApp : .browser
            let identifier = browser.map { "browser:\($0.bundleIdentifier)" }
                ?? "native:\(canonicalBundleIdentifier)"
            let candidate = MeetingCandidate(
                id: identifier,
                appName: name,
                bundleIdentifier: canonicalBundleIdentifier,
                processIdentifier: hostApp?.processIdentifier ?? pid,
                trigger: trigger
            )

            let state = ProcessState(
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

            if let existing = states[identifier] {
                states[identifier] = ProcessState(
                    candidate: existing.candidate,
                    runningInput: existing.runningInput || state.runningInput,
                    runningOutput: existing.runningOutput || state.runningOutput
                )
            } else {
                states[identifier] = state
            }
        }

        var result = Array(states.values)
        let hasBrowserInput = result.contains {
            $0.candidate.trigger == .browser && $0.runningInput
        }
        let hasNativeInput = result.contains {
            $0.candidate.trigger == .nativeApp && $0.runningInput
        }
        if !hasBrowserInput,
           !hasNativeInput,
           defaultInputIsRunning(),
           let fallback = fallbackBrowserState(from: result) {
            result.removeAll { $0.candidate.id == fallback.candidate.id }
            result.append(fallback)
        }
        return result
    }

    private static func runningHost(bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }
    }

    private static func fallbackBrowserState(from states: [ProcessState]) -> ProcessState? {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let outputState = states.first(where: {
            $0.candidate.trigger == .browser
                && $0.runningOutput
                && $0.candidate.processIdentifier == frontmostPID
        }) else { return nil }

        return ProcessState(
            candidate: outputState.candidate,
            runningInput: true,
            runningOutput: true
        )
    }

    private static func defaultInputIsRunning() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr,
        deviceID != kAudioObjectUnknown else { return false }

        return booleanProperty(
            kAudioDevicePropertyDeviceIsRunningSomewhere,
            objectID: deviceID,
            scope: kAudioObjectPropertyScopeInput
        )
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
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr,
        let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
