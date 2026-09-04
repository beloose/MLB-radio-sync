import AVFoundation
import XCTest
@testable import RadioSync

final class PCMSinkTests: XCTestCase {

    private func makeBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: Int, interleaved: Bool = false, fill: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData!
        for channel in 0..<Int(channels) {
            for frame in 0..<frames {
                if interleaved {
                    data[0][frame * Int(channels) + channel] = fill(channel, frame)
                } else {
                    data[channel][frame] = fill(channel, frame)
                }
            }
        }
        return buffer
    }

    func testMonoAtRingRateIsCopiedVerbatim() {
        let ring = PCMRingBuffer(minimumCapacity: 4096)
        let sink = PCMSink(ring: ring, sampleRate: 48_000)
        sink.write(makeBuffer(sampleRate: 48_000, channels: 1, frames: 500) { _, frame in Float(frame) })
        XCTAssertEqual(ring.writePosition, 500)
        for frame in 0..<500 { XCTAssertEqual(ring.sample(at: frame), Float(frame)) }
    }

    func testStereoIsAveragedToMono() {
        let ring = PCMRingBuffer(minimumCapacity: 4096)
        let sink = PCMSink(ring: ring, sampleRate: 48_000)
        sink.write(makeBuffer(sampleRate: 48_000, channels: 2, frames: 100) { channel, frame in channel == 0 ? Float(frame) : Float(frame) + 10 })
        XCTAssertEqual(ring.writePosition, 100)
        for frame in 0..<100 { XCTAssertEqual(ring.sample(at: frame), Float(frame) + 5, accuracy: 0.001) }
    }

    func testInterleavedStereoIsAveragedToMono() {
        let ring = PCMRingBuffer(minimumCapacity: 4096)
        let sink = PCMSink(ring: ring, sampleRate: 48_000)
        sink.write(makeBuffer(sampleRate: 48_000, channels: 2, frames: 100, interleaved: true) { channel, frame in channel == 0 ? 1 : Float(frame) })
        XCTAssertEqual(ring.writePosition, 100)
        for frame in 0..<100 { XCTAssertEqual(ring.sample(at: frame), (1 + Float(frame)) / 2, accuracy: 0.001) }
    }

    func testDifferentSampleRateIsResampled() {
        let ring = PCMRingBuffer(minimumCapacity: 1 << 16)
        let sink = PCMSink(ring: ring, sampleRate: 48_000)
        // Feed 1 s of 44.1 kHz DC in ten chunks; expect ~48k frames of the same level.
        for _ in 0..<10 {
            sink.write(makeBuffer(sampleRate: 44_100, channels: 1, frames: 4410) { _, _ in 0.5 })
        }
        XCTAssertEqual(Double(ring.writePosition), 48_000, accuracy: 48_000 * 0.05)
        // Skip the converter's warm-up region and check the level held.
        let position = ring.writePosition - 1000
        XCTAssertEqual(ring.sample(at: position), 0.5, accuracy: 0.02)
    }
}
