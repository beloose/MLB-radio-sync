import XCTest
@testable import RadioSync

/// Drives a `DelayReader` with a deterministic source whose sample value equals
/// its absolute frame position, so any output frame reveals exactly which source
/// frame it came from.
///
/// Two ways to drive it:
/// - `cycle(write:render:)` writes a chunk then renders, with no notion of time.
///   Fine for tests that look at what comes out; only compare distances with
///   `measuredDelay` when writes and renders are the same size.
/// - `tick()` is a real-time simulation: 64 frames rendered and 64 frames
///   captured per tick, with the capture flushed to the ring in 100-frame chunks
///   the way an input tap would. `trueDelay` measures against the capture clock,
///   so it is immune to chunk phase.
private final class Harness {
    let ring: PCMRingBuffer
    let reader: DelayReader
    private(set) var written = 0
    private(set) var pendingCapture = 0
    private(set) var output: [Float] = []

    init(delay: Int, crossfade: Int = 20, capacity: Int = 20_000, maxDelay: Int = 10_000, guardFrames: Int = 50) {
        ring = PCMRingBuffer(minimumCapacity: capacity)
        reader = DelayReader(ring: ring, sampleRate: 1000, maxDelayFrames: maxDelay, crossfadeFrames: crossfade, guardFrames: guardFrames)
        reader.setDelay(frames: delay)
    }

    func write(_ frames: Int) {
        ring.write((written..<(written + frames)).map(Float.init))
        written += frames
    }

    @discardableResult
    func render(_ frames: Int) -> [Float] {
        var out = [Float](repeating: -1, count: frames)
        out.withUnsafeMutableBufferPointer { buffer in
            reader.render(into: buffer.baseAddress!, frameCount: frames)
        }
        output.append(contentsOf: out)
        return out
    }

    @discardableResult
    func cycle(write writeFrames: Int = 100, render renderFrames: Int = 100) -> [Float] {
        write(writeFrames)
        return render(renderFrames)
    }

    func cycles(_ count: Int, write writeFrames: Int = 100, render renderFrames: Int = 100) {
        for _ in 0..<count { cycle(write: writeFrames, render: renderFrames) }
    }

    /// One real-time step: capture 64 frames (flushed in 100-frame chunks), render 64.
    @discardableResult
    func tick() -> [Float] {
        pendingCapture += 64
        while pendingCapture >= 100 {
            write(100)
            pendingCapture -= 100
        }
        return render(64)
    }

    /// Frames captured so far, flushed or not: the capture clock.
    var captured: Int { written + pendingCapture }

    /// Writer/reader distance at the start of the render that produced `out`.
    /// Exact only when writes and renders are the same size. `index` must be
    /// outside any crossfade.
    func measuredDelay(of out: [Float], at index: Int) -> Int {
        ring.writePosition - (Int(out[index]) - index)
    }

    /// Capture-clock/reader distance at the start of the render that produced `out`.
    /// Constant in steady state under `tick()`. `index` must be outside any crossfade.
    func trueDelay(of out: [Float], at index: Int) -> Int {
        captured - (Int(out[index]) - index)
    }
}

final class DelayReaderTests: XCTestCase {

    func testSilentUntilAnchored() {
        let h = Harness(delay: 500)
        h.write(300)
        XCTAssertTrue(h.render(100).allSatisfy { $0 == 0 })
        XCTAssertEqual(h.reader.snapshot.phase, .idle)
    }

    func testFillsThenPlaysAtRequestedDelay() {
        let h = Harness(delay: 500)
        h.reader.anchor(at: h.ring.writePosition)

        h.cycles(4)  // 400 frames available: still filling
        XCTAssertEqual(h.reader.snapshot.phase, .filling)
        XCTAssertEqual(h.reader.snapshot.fillProgress, 0.8, accuracy: 0.01)
        XCTAssertTrue(h.output.allSatisfy { $0 == 0 })

        let out = h.cycle()  // 500 available: playback starts at frame 0
        XCTAssertEqual(h.reader.snapshot.phase, .playing)
        XCTAssertEqual(h.reader.snapshot.fillProgress, 1, accuracy: 0.001)
        // First `crossfade` frames fade in from silence; afterwards output is exact.
        XCTAssertLessThan(out[0], 1)
        for index in 20..<100 {
            XCTAssertEqual(out[index], Float(index), accuracy: 0.001)
        }
        XCTAssertEqual(h.measuredDelay(of: out, at: 50), 500)

        // Steady state: consecutive frames, constant delay.
        let next = h.cycle()
        for index in 1..<100 {
            XCTAssertEqual(next[index], next[index - 1] + 1, accuracy: 0.001)
        }
        XCTAssertEqual(h.measuredDelay(of: next, at: 0), 500)
        XCTAssertEqual(h.reader.snapshot.delayFrames, 500)
    }

    func testZeroDelaySettlesToOneChunkOfLatency() {
        let h = Harness(delay: 0, crossfade: 0)
        h.reader.anchor(at: 0)
        // The fill completes on the first chunk and the reader jumps to the live
        // edge, which has nothing to play yet: one chunk of stall.
        let first = h.cycle()
        XCTAssertTrue(first.allSatisfy { $0 == 0 })
        XCTAssertEqual(h.reader.snapshot.phase, .playing)
        // The stall became delay, so the reported value stays truthful.
        XCTAssertEqual(h.reader.snapshot.delayFrames, 100)
        let second = h.cycle()
        for index in 0..<100 { XCTAssertEqual(second[index], Float(100 + index)) }
        XCTAssertEqual(h.measuredDelay(of: second, at: 0), 100)
        XCTAssertEqual(h.reader.snapshot.delayFrames, 100)
    }

    func testNudgeMovesExactlyByTheStepRegardlessOfChunkPhase() {
        let h = Harness(delay: 500, crossfade: 8)
        h.reader.anchor(at: 0)
        for _ in 0..<40 { h.tick() }
        XCTAssertEqual(h.reader.snapshot.phase, .playing)

        let before = h.tick()
        let delayBefore = h.trueDelay(of: before, at: 20)
        XCTAssertGreaterThanOrEqual(delayBefore, 500)
        XCTAssertLessThan(delayBefore, 600)  // requested delay plus up to one chunk of tap latency

        h.reader.setDelay(frames: 600)
        h.tick()  // crossfade happens in this buffer
        let after = h.tick()
        XCTAssertEqual(h.trueDelay(of: after, at: 20) - delayBefore, 100)
        XCTAssertEqual(h.reader.snapshot.delayFrames, 600)

        h.reader.setDelay(frames: 350)
        h.tick()
        let shorter = h.tick()
        XCTAssertEqual(h.trueDelay(of: shorter, at: 20) - delayBefore, -150)
        XCTAssertEqual(h.reader.snapshot.delayFrames, 350)
    }

    func testCrossfadeBlendsOldAndNewStreams() {
        let h = Harness(delay: 500, crossfade: 20)
        h.reader.anchor(at: 0)
        h.cycles(8)
        h.reader.setDelay(frames: 600)
        let out = h.cycle()
        let newStart = Int(out[20]) - 20   // source position of frame 0 on the new stream
        for index in 0..<20 {
            let new = Float(newStart + index)
            let old = new + 100
            XCTAssertGreaterThanOrEqual(out[index], new - 0.001, "frame \(index)")
            XCTAssertLessThanOrEqual(out[index], old * 1.42, "frame \(index)")  // equal-power sum peaks at √2
        }
        for index in 20..<100 {
            XCTAssertEqual(out[index], Float(newStart + index), accuracy: 0.001)
        }
    }

    func testDelayIsClampedToRange() {
        let h = Harness(delay: 500, maxDelay: 1000)
        h.reader.anchor(at: 0)
        h.cycles(6)
        h.reader.setDelay(frames: -50)
        h.cycle()
        // Clamped to 0, which then stalls to at most one chunk (see the zero-delay test).
        XCTAssertLessThanOrEqual(h.reader.snapshot.delayFrames, 100)
        h.reader.setDelay(frames: 5000)
        h.cycles(12)
        XCTAssertEqual(h.reader.snapshot.delayFrames, 1000)
    }

    func testDelayBeyondHistoryRefillsFromTheAnchor() {
        let h = Harness(delay: 500)
        h.reader.anchor(at: 0)
        h.cycles(10)  // 1000 frames written, playing
        XCTAssertEqual(h.reader.snapshot.phase, .playing)

        h.reader.setDelay(frames: 3000)
        let held = h.cycle()
        XCTAssertEqual(h.reader.snapshot.phase, .filling)
        XCTAssertTrue(held.allSatisfy { $0 == 0 })
        XCTAssertEqual(h.reader.snapshot.fillProgress, 1100.0 / 3000.0, accuracy: 0.001)

        h.cycles(18)  // 2900 written: still filling
        XCTAssertEqual(h.reader.snapshot.phase, .filling)
        let out = h.cycle()  // 3000 written: plays from frame 0 at delay 3000
        XCTAssertEqual(h.reader.snapshot.phase, .playing)
        for index in 20..<100 {
            XCTAssertEqual(out[index], Float(index), accuracy: 0.001)
        }
        XCTAssertEqual(h.measuredDelay(of: out, at: 50), 3000)
    }

    func testPauseFreezesOutputAndGrowsDelay() {
        let h = Harness(delay: 500)
        h.reader.anchor(at: 0)
        h.cycles(8)
        let before = h.cycle()
        let lastValue = before[99]

        h.reader.setPaused(true)
        for _ in 0..<3 {
            XCTAssertTrue(h.cycle().allSatisfy { $0 == 0 })
        }
        XCTAssertTrue(h.reader.snapshot.isPaused)
        XCTAssertEqual(h.reader.snapshot.delayFrames, 800)

        h.reader.setPaused(false)
        let resumed = h.cycle()
        XCTAssertEqual(resumed[0], lastValue + 1, accuracy: 0.001)   // continues where it left off
        XCTAssertEqual(h.measuredDelay(of: resumed, at: 0), 800)
    }

    func testPauseIsCappedAtMaxDelay() {
        let h = Harness(delay: 500, maxDelay: 1000)
        h.reader.anchor(at: 0)
        h.cycles(8)
        h.reader.setPaused(true)
        h.cycles(8)  // would be 1300 uncapped
        XCTAssertEqual(h.reader.snapshot.delayFrames, 1000)
        h.reader.setPaused(false)
        let resumed = h.cycle()
        XCTAssertEqual(h.measuredDelay(of: resumed, at: 0), 1000)
    }

    func testReanchorSkipsToTheRequestedDelayAfterAnOutage() {
        let h = Harness(delay: 500, crossfade: 0)
        h.reader.anchor(at: 0)
        h.cycles(8)
        // Outage: the source kept writing but nothing rendered.
        h.write(300)
        h.reader.reanchor()
        let out = h.cycle()
        XCTAssertEqual(h.measuredDelay(of: out, at: 0), 500)
        XCTAssertEqual(h.reader.snapshot.delayFrames, 500)
    }

    func testAnchorRestartsFromNewSource() {
        let h = Harness(delay: 200, crossfade: 0)
        h.reader.anchor(at: 0)
        h.cycles(5)
        XCTAssertEqual(h.reader.snapshot.phase, .playing)
        // A new source starts writing at the current position.
        h.reader.anchor(at: h.ring.writePosition)
        let start = h.ring.writePosition
        h.cycle()
        XCTAssertEqual(h.reader.snapshot.phase, .filling)
        let out = h.cycle()
        XCTAssertEqual(h.reader.snapshot.phase, .playing)
        XCTAssertEqual(out[0], Float(start), accuracy: 0.001)
    }

    func testSnapshotIsUnsettledUntilTheRenderThreadAppliesCommands() {
        let h = Harness(delay: 100)
        h.reader.anchor(at: 0)
        XCTAssertFalse(h.reader.snapshot.isSettled)
        h.render(10)
        XCTAssertTrue(h.reader.snapshot.isSettled)
        h.reader.setDelay(frames: 200)
        XCTAssertFalse(h.reader.snapshot.isSettled)
        h.render(10)
        XCTAssertTrue(h.reader.snapshot.isSettled)
        XCTAssertEqual(h.reader.snapshot.delayFrames, 200)
    }

    func testReportedDelayTracksTrueDelayUnderMixedChunking() {
        // Long real-time run with random nudges and pauses thrown in. Afterwards
        // the reported delay must match the capture-clock distance to within one
        // chunk of tap latency.
        var rng = SplitMix64(seed: 7)
        let h = Harness(delay: 3000, crossfade: 50, capacity: 100_000, maxDelay: 60_000, guardFrames: 1000)
        h.reader.anchor(at: 0)
        for step in 0..<6000 {
            h.tick()
            if step % 97 == 0 { h.reader.setDelay(frames: Int(rng.next() % 7500) + 500) }
            if step % 401 == 0 { h.reader.setPaused(true) }
            if step % 401 == 50 { h.reader.setPaused(false) }
        }
        h.reader.setPaused(false)
        for _ in 0..<400 { h.tick() }
        let out = h.tick()
        let snapshot = h.reader.snapshot
        XCTAssertEqual(snapshot.phase, .playing)
        XCTAssertTrue(snapshot.isSettled)
        let trueDelay = h.trueDelay(of: out, at: 60)
        XCTAssertGreaterThanOrEqual(trueDelay - snapshot.delayFrames, 0)
        XCTAssertLessThan(trueDelay - snapshot.delayFrames, 100, "true \(trueDelay) vs reported \(snapshot.delayFrames)")
    }
}

/// Deterministic RNG so the stress test is reproducible.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
