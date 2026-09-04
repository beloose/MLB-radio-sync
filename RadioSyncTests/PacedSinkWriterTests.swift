import AVFoundation
import XCTest
@testable import RadioSync

final class PacedSinkWriterTests: XCTestCase {

    private func buffer(rate: Double, channels: AVAudioChannelCount, frames: Int, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            for frame in 0..<frames { buffer.floatChannelData![channel][frame] = value + Float(frame) }
        }
        return buffer
    }

    func testQueueSplitsBuffersAtFrameBoundaries() {
        let queue = PCMQueue()
        queue.enqueue(buffer(rate: 1000, channels: 2, frames: 1000, value: 0))   // 1.0 s
        queue.enqueue(buffer(rate: 1000, channels: 2, frames: 500, value: 5000)) // 0.5 s
        XCTAssertEqual(queue.queuedSeconds, 1.5, accuracy: 1e-9)

        let first = queue.dequeue(seconds: 0.25)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].frameLength, 250)
        XCTAssertEqual(first[0].floatChannelData![1][0], 0)
        XCTAssertEqual(queue.queuedSeconds, 1.25, accuracy: 1e-9)

        let second = queue.dequeue(seconds: 1.0)  // rest of the first buffer (750) + 250 of the second
        XCTAssertEqual(second.map { Int($0.frameLength) }, [750, 250])
        XCTAssertEqual(second[0].floatChannelData![0][0], 250)
        XCTAssertEqual(second[1].floatChannelData![0][0], 5000)
        XCTAssertEqual(queue.queuedSeconds, 0.25, accuracy: 1e-9)

        let rest = queue.dequeue(seconds: 10)
        XCTAssertEqual(rest.map { Int($0.frameLength) }, [250])
        XCTAssertEqual(rest[0].floatChannelData![0][0], 5250)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.queuedSeconds, 0)
    }

    func testConcatenateJoinsMatchingFormats() {
        let a = buffer(rate: 48_000, channels: 1, frames: 10, value: 0)
        let b = buffer(rate: 48_000, channels: 1, frames: 5, value: 100)
        let merged = PCMQueue.concatenate([a, b])
        XCTAssertEqual(merged?.frameLength, 15)
        XCTAssertEqual(merged?.floatChannelData![0][9], 9)
        XCTAssertEqual(merged?.floatChannelData![0][10], 100)
        let other = buffer(rate: 44_100, channels: 1, frames: 5, value: 0)
        XCTAssertNil(PCMQueue.concatenate([a, other]), "mixed formats are not merged")
    }

    func testBeginWritesBurstAsOneRingWriteThenPacesInRealTime() async throws {
        let ring = PCMRingBuffer(minimumCapacity: 48_000 * 10)
        let sink = PCMSink(ring: ring, sampleRate: 48_000)
        let queue = PCMQueue()
        let writer = PacedSinkWriter(queue: queue, sink: sink)
        queue.enqueue(buffer(rate: 48_000, channels: 1, frames: 48_000 * 3, value: 0))  // 3 s

        writer.begin(burstSeconds: 2)
        XCTAssertEqual(ring.writePosition, 96_000, "2 s burst lands immediately")
        XCTAssertEqual(queue.queuedSeconds, 1, accuracy: 1e-9)
        XCTAssertEqual(writer.stats.cushionSeconds, 1, accuracy: 1e-9)

        writer.start()
        defer { writer.stop() }
        try await Task.sleep(for: .milliseconds(550))
        let written = Double(ring.writePosition) / 48_000
        XCTAssertGreaterThan(written, 2.35, "about half a second more should have been paced in")
        XCTAssertLessThan(written, 2.75)
        XCTAssertLessThan(writer.stats.shortfallSeconds, 0.15)
    }

    func testResyncFillsTheShortfallWithSilence() async throws {
        let ring = PCMRingBuffer(minimumCapacity: 48_000 * 10)
        let sink = PCMSink(ring: ring, sampleRate: 48_000)
        let queue = PCMQueue()
        let writer = PacedSinkWriter(queue: queue, sink: sink)
        queue.enqueue(buffer(rate: 48_000, channels: 1, frames: 4_800, value: 1))  // 0.1 s only
        writer.begin(burstSeconds: 0)
        writer.start()
        defer { writer.stop() }
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(ring.writePosition, 4_800, "queue ran dry: nothing more is written")
        XCTAssertGreaterThan(writer.stats.shortfallSeconds, 0.25)

        writer.resync()
        queue.enqueue(buffer(rate: 48_000, channels: 1, frames: 48_000, value: 1))  // fresh content after the outage
        try await Task.sleep(for: .milliseconds(250))
        let position = ring.writePosition
        XCTAssertGreaterThan(position, 4_800 + 48_000 / 4, "silence filled the gap, then content resumed")
        XCTAssertEqual(ring.sample(at: 4_800 + 100), 0, "the gap is silence")
        XCTAssertGreaterThanOrEqual(ring.sample(at: position - 1), 1, "fresh content follows")
        XCTAssertLessThan(writer.stats.shortfallSeconds, 0.15)
    }
}
