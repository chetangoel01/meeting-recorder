import AVFoundation
import XCTest
@testable import MeetingRecorder

final class AudioFormatCompatibilityTests: XCTestCase {
    private func format(rate: Double, channels: UInt32) -> CMFormatDescription {
        AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!.formatDescription
    }

    func testSampleRateChangeStaysOnTheSameWriter() {
        XCTAssertTrue(AudioFormatCompatibility.isCompatible(
            format(rate: 48_000, channels: 1), format(rate: 16_000, channels: 1)
        ))
    }

    func testChannelCountChangeRotatesTheWriter() {
        XCTAssertFalse(AudioFormatCompatibility.isCompatible(
            format(rate: 48_000, channels: 1), format(rate: 48_000, channels: 2)
        ))
    }
}
