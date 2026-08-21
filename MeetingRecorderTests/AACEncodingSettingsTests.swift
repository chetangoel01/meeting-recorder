import AVFoundation
import XCTest
@testable import MeetingRecorder

// Limits measured against the AAC encoder on macOS 26: bitrate ceiling is
// about 3x the sample rate per channel, and only the listed sample rates
// are encodable at all.
final class AACEncodingSettingsTests: XCTestCase {
    private func settings(_ rate: Double, _ channels: Int) -> [String: Any] {
        AACEncodingSettings.outputSettings(sourceSampleRate: rate, channelCount: channels)
    }

    func testKeepsFullBitrateForStandardRates() {
        XCTAssertEqual(settings(48_000, 1)[AVEncoderBitRateKey] as? Int, 96_000)
        XCTAssertEqual(settings(48_000, 2)[AVEncoderBitRateKey] as? Int, 96_000)
        XCTAssertEqual(settings(32_000, 1)[AVEncoderBitRateKey] as? Int, 96_000)
    }

    func testClampsBitrateForLowRateMicrophones() {
        XCTAssertEqual(settings(16_000, 1)[AVEncoderBitRateKey] as? Int, 48_000)
        XCTAssertEqual(settings(22_050, 1)[AVEncoderBitRateKey] as? Int, 66_150)
        XCTAssertEqual(settings(24_000, 1)[AVEncoderBitRateKey] as? Int, 72_000)
        XCTAssertEqual(settings(16_000, 2)[AVEncoderBitRateKey] as? Int, 96_000)
    }

    func testOmitsBitrateBelowSixteenKilohertz() {
        XCTAssertNil(settings(8_000, 1)[AVEncoderBitRateKey])
        XCTAssertEqual(settings(8_000, 1)[AVSampleRateKey] as? Double, 8_000)
    }

    func testFallsBackToFortyEightKilohertzForUnencodableRates() {
        XCTAssertEqual(settings(96_000, 2)[AVSampleRateKey] as? Double, 48_000)
        XCTAssertEqual(settings(88_200, 1)[AVSampleRateKey] as? Double, 48_000)
        XCTAssertEqual(settings(44_100, 1)[AVSampleRateKey] as? Double, 44_100)
    }
}
