import Foundation

// Decides, once per health tick, what to do about the optional microphone.
// A stalled or unwritable microphone gets one stream restart, which
// re-resolves the device; if it is still broken afterwards the recording
// degrades to call audio only and picks the microphone back up on its own
// when samples return. The restart is a budget per loss, not per call: once
// the microphone has flowed for a sustained stretch after its restart it earns
// a fresh one, so a second Bluetooth dropout later in a long call is retried
// instead of silently degrading — while a microphone that bursts and stalls
// repeatedly still cannot pull the stream into a restart loop.
struct MicrophoneHealthPolicy: Equatable {
    enum Action: Equatable {
        case none
        case restart
        case degrade
        case resume
    }

    struct Observation {
        var available: Bool
        var stalled: Bool
        var writerFailed: Bool
        var hasReceivedSamples: Bool
        var now: Date
    }

    let replenishAfter: TimeInterval
    private(set) var restartUsed = false
    private var healthySince: Date?

    init(replenishAfter: TimeInterval = 30) {
        self.replenishAfter = replenishAfter
    }

    mutating func evaluate(_ observation: Observation) -> Action {
        let broken = observation.stalled || observation.writerFailed
        if observation.available, broken {
            healthySince = nil
            if restartUsed { return .degrade }
            restartUsed = true
            return .restart
        }
        if !observation.available, !broken, observation.hasReceivedSamples {
            restartUsed = false
            healthySince = nil
            return .resume
        }
        if observation.available, restartUsed {
            let since = healthySince ?? observation.now
            healthySince = since
            if observation.now.timeIntervalSince(since) >= replenishAfter {
                restartUsed = false
                healthySince = nil
            }
        }
        return .none
    }
}
