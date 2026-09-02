import AVFoundation
import CoreMedia
import XCTest
@testable import MeetingRecorder

// The encoder accepts only a per-rate, per-channel set of bitrates, so the
// settings are checked against the encoder itself rather than pinned numbers:
// the old "3x the sample rate" rule produced 72 kbps for a 24 kHz mono
// Bluetooth microphone, which the encoder rejects at startWriting.
final class AACEncodingSettingsTests: XCTestCase {
    private func settings(_ rate: Double, _ channels: Int) -> [String: Any] {
        AACEncodingSettings.outputSettings(sourceSampleRate: rate, channelCount: channels)
    }

    func testKeepsFullBitrateForStandardRates() {
        XCTAssertEqual(settings(48_000, 1)[AVEncoderBitRateKey] as? Int, 96_000)
        XCTAssertEqual(settings(48_000, 2)[AVEncoderBitRateKey] as? Int, 96_000)
        XCTAssertEqual(settings(32_000, 1)[AVEncoderBitRateKey] as? Int, 96_000)
        XCTAssertEqual(settings(16_000, 2)[AVEncoderBitRateKey] as? Int, 96_000)
    }

    func testClampsBitrateForLowRateMicrophones() {
        XCTAssertEqual(settings(16_000, 1)[AVEncoderBitRateKey] as? Int, 48_000)
        XCTAssertEqual(settings(22_050, 1)[AVEncoderBitRateKey] as? Int, 64_000)
        XCTAssertEqual(settings(24_000, 1)[AVEncoderBitRateKey] as? Int, 64_000)
    }

    func testChosenBitrateIsOneTheEncoderLists() {
        for rate in AACEncodingSettings.aacSampleRates {
            for channels in 1...2 {
                let applicable = AACEncodingSettings.applicableBitRates(sampleRate: rate, channelCount: channels)
                XCTAssertNotNil(applicable, "encoder could not be queried at \(rate) Hz x\(channels)")
                guard let bitRate = settings(rate, channels)[AVEncoderBitRateKey] as? Int else {
                    XCTFail("no bitrate chosen at \(rate) Hz x\(channels)")
                    continue
                }
                XCTAssertLessThanOrEqual(bitRate, AACEncodingSettings.preferredBitRate)
                XCTAssertTrue(
                    applicable?.contains { $0.contains(bitRate) } ?? false,
                    "\(bitRate) bps is not applicable at \(rate) Hz x\(channels): \(applicable ?? [])"
                )
            }
        }
    }

    func testFallbackNeverExceedsMeasuredCeilings() {
        XCTAssertEqual(AACEncodingSettings.fallbackBitRate(sampleRate: 16_000, channelCount: 1), 48_000)
        XCTAssertEqual(AACEncodingSettings.fallbackBitRate(sampleRate: 24_000, channelCount: 1), 64_000)
        XCTAssertEqual(AACEncodingSettings.fallbackBitRate(sampleRate: 22_050, channelCount: 1), 64_000)
        XCTAssertEqual(AACEncodingSettings.fallbackBitRate(sampleRate: 24_000, channelCount: 2), 96_000)
        XCTAssertEqual(AACEncodingSettings.fallbackBitRate(sampleRate: 48_000, channelCount: 2), 96_000)
        XCTAssertNil(AACEncodingSettings.fallbackBitRate(sampleRate: 8_000, channelCount: 1))
    }

    func testFallsBackToFortyEightKilohertzForUnencodableRates() {
        XCTAssertEqual(settings(96_000, 2)[AVSampleRateKey] as? Double, 48_000)
        XCTAssertEqual(settings(88_200, 1)[AVSampleRateKey] as? Double, 48_000)
        XCTAssertEqual(settings(44_100, 1)[AVSampleRateKey] as? Double, 44_100)
    }

    // Round-trip through the same AVAssetWriter path the recorder uses, for
    // every rate and channel count a capture device can present.
    func testEveryEncodableFormatWritesThroughAssetWriter() throws {
        for rate in AACEncodingSettings.aacSampleRates {
            for channels in 1...2 {
                try assertWrites(sampleRate: rate, channels: channels)
            }
        }
    }

    private func assertWrites(sampleRate: Double, channels: Int) throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "aac-settings-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let sampleBuffer = try Self.silentSampleBuffer(sampleRate: sampleRate, channels: UInt32(channels), frames: 4_800)
        let outputSettings = settings(sampleRate, channels)
        let writer = try AVAssetWriter(url: url, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings,
            sourceFormatHint: CMSampleBufferGetFormatDescription(sampleBuffer)
        )
        input.expectsMediaDataInRealTime = true
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)

        let label = "\(Int(sampleRate)) Hz x\(channels) @ \(outputSettings[AVEncoderBitRateKey] ?? "default")"
        XCTAssertTrue(writer.startWriting(), "\(label): \(writer.error?.localizedDescription ?? "startWriting failed")")
        writer.startSession(atSourceTime: .zero)
        XCTAssertTrue(input.append(sampleBuffer), "\(label): \(writer.error?.localizedDescription ?? "append failed")")
        input.markAsFinished()

        let finished = expectation(description: label)
        writer.finishWriting { finished.fulfill() }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(writer.status, .completed, "\(label): \(writer.error?.localizedDescription ?? "not completed")")
    }

    private static func silentSampleBuffer(sampleRate: Double, channels: UInt32, frames: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &formatDescription
        ))
        let byteCount = frames * Int(description.mBytesPerFrame)
        var blockBuffer: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0,
            blockBufferOut: &blockBuffer
        ))
        guard let blockBuffer, let formatDescription else { throw Failure.setup }
        try check(CMBlockBufferFillDataBytes(with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount))
        var sampleBuffer: CMSampleBuffer?
        try check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: blockBuffer, formatDescription: formatDescription,
            sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ))
        guard let sampleBuffer else { throw Failure.setup }
        return sampleBuffer
    }

    private enum Failure: Error { case setup, status(OSStatus) }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw Failure.status(status) }
    }
}
