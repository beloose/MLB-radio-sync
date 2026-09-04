import Foundation
import Synchronization

/// Pulls delayed audio out of a `PCMRingBuffer`.
///
/// The reader keeps its own absolute read position and plays `delay` frames
/// behind the writer. `render(into:frameCount:)` is designed for the audio render
/// thread: it never allocates, locks, or blocks. Every other method may be called
/// from any thread; they hand commands to the render thread through atomics and
/// the render thread publishes its state back the same way.
///
/// Delay semantics:
/// - Changing the delay moves the read position *relative* to where it is now,
///   with a short equal-power crossfade so nudges don't click. Relative moves keep
///   whatever constant offset the source's chunking introduced, so a +0.1 s nudge
///   is always exactly +0.1 s.
/// - If the requested delay reaches further back than the ring holds since the
///   source started, the reader holds (silence) until enough audio has
///   accumulated — the "buffering to +Xs" state.
/// - Pausing freezes the read position while the source keeps writing, so the
///   delay grows by the paused duration (capped at `maxDelayFrames`). An underrun
///   (source not keeping up) is accounted the same way, so the reported delay is
///   always the true distance between reader and writer.
final class DelayReader: @unchecked Sendable {

    enum Phase: Int {
        /// No source anchored yet. Output is silence.
        case idle = 0
        /// Waiting for the ring to accumulate `delay` frames since the anchor.
        case filling = 1
        /// Steady state: reading `delay` frames behind the writer.
        case playing = 2
    }

    struct Snapshot: Equatable {
        var phase: Phase
        /// Current delay in frames, including growth from pauses and underruns.
        var delayFrames: Int
        /// 0...1 while `phase == .filling`.
        var fillProgress: Double
        var isPaused: Bool
        /// True once the render thread has applied every command sent so far.
        /// Until then `delayFrames` may still reflect the previous command.
        var isSettled: Bool
    }

    let ring: PCMRingBuffer
    let sampleRate: Double
    let maxDelayFrames: Int
    let crossfadeFrames: Int
    let guardFrames: Int

    // MARK: Command mailbox (any thread → render thread)

    private static let noCommand = -1
    private let pendingDelay = Atomic<Int>(DelayReader.noCommand)
    private let pendingAnchor = Atomic<Int>(DelayReader.noCommand)
    private let pendingReanchor = Atomic<Bool>(false)
    private let pauseFlag = Atomic<Bool>(false)
    private let commandSequence = Atomic<Int>(0)

    // MARK: Published state (render thread → any thread)

    private let publishedPhase = Atomic<Int>(0)
    private let publishedDelay = Atomic<Int>(0)
    private let publishedFillPermille = Atomic<Int>(0)
    private let appliedSequence = Atomic<Int>(0)

    // MARK: Render-thread-only state

    private var phase: Phase = .idle
    private var readPos = 0
    private var anchorPos = 0
    private var delayFrames = 0
    private var fadeFromPos = -1
    private var fadeRemaining = 0

    init(ring: PCMRingBuffer, sampleRate: Double, maxDelayFrames: Int, crossfadeFrames: Int, guardFrames: Int) {
        precondition(maxDelayFrames + guardFrames < ring.capacity, "max delay must fit inside the ring")
        self.ring = ring
        self.sampleRate = sampleRate
        self.maxDelayFrames = maxDelayFrames
        self.crossfadeFrames = max(0, crossfadeFrames)
        self.guardFrames = guardFrames
    }

    // MARK: Commands

    /// Declares that a source has just started writing at `position`. The reader
    /// restarts from there: it fills to the current delay, then plays.
    func anchor(at position: Int) {
        pendingAnchor.store(max(0, position), ordering: .releasing)
        commandSequence.wrappingAdd(1, ordering: .releasing)
    }

    /// Sets the delay in frames (clamped to `0...maxDelayFrames`).
    /// - Parameter reanchor: place the read position at `writePosition - delay`
    ///   instead of moving relative to the current read position. Use after an
    ///   outage (interruption, route change) to re-establish the requested delay.
    func setDelay(frames: Int, reanchor: Bool = false) {
        let clamped = min(max(frames, 0), maxDelayFrames)
        if reanchor {
            pendingReanchor.store(true, ordering: .releasing)
        }
        pendingDelay.store(clamped, ordering: .releasing)
        commandSequence.wrappingAdd(1, ordering: .releasing)
    }

    /// Re-establishes the current delay relative to the writer. See `setDelay(frames:reanchor:)`.
    func reanchor() {
        pendingReanchor.store(true, ordering: .releasing)
        commandSequence.wrappingAdd(1, ordering: .releasing)
    }

    func setPaused(_ paused: Bool) {
        pauseFlag.store(paused, ordering: .releasing)
        commandSequence.wrappingAdd(1, ordering: .releasing)
    }

    var snapshot: Snapshot {
        let applied = appliedSequence.load(ordering: .acquiring)
        let sent = commandSequence.load(ordering: .acquiring)
        return Snapshot(
            phase: Phase(rawValue: publishedPhase.load(ordering: .relaxed)) ?? .idle,
            delayFrames: publishedDelay.load(ordering: .relaxed),
            fillProgress: Double(publishedFillPermille.load(ordering: .relaxed)) / 1000,
            isPaused: pauseFlag.load(ordering: .relaxed),
            isSettled: applied == sent
        )
    }

    // MARK: Render thread

    /// Fills `output` with `frameCount` mono frames.
    /// - Returns: false if every frame written was silence.
    @discardableResult
    func render(into output: UnsafeMutablePointer<Float>, frameCount: Int) -> Bool {
        let sequence = commandSequence.load(ordering: .acquiring)
        applyPendingCommands()
        let writePos = ring.writePosition
        var produced = false

        switch phase {
        case .idle:
            output.update(repeating: 0, count: frameCount)

        case .filling:
            // Wait for the source to actually produce audio before playing, even
            // at zero delay: a network source's first write can be a burst of
            // history, and the read position must be placed relative to it.
            let available = writePos - readPos
            if available >= delayFrames && available > 0 {
                readPos = writePos - delayFrames
                phase = .playing
                beginFade(from: -1)
                publishedFillPermille.store(1000, ordering: .relaxed)
                produced = renderPlaying(into: output, frameCount: frameCount, writePos: writePos)
            } else {
                output.update(repeating: 0, count: frameCount)
                let permille = delayFrames > 0 ? (available * 1000) / delayFrames : 1000
                publishedFillPermille.store(min(max(permille, 0), 1000), ordering: .relaxed)
            }

        case .playing:
            produced = renderPlaying(into: output, frameCount: frameCount, writePos: writePos)
        }

        publishedPhase.store(phase.rawValue, ordering: .relaxed)
        publishedDelay.store(delayFrames, ordering: .relaxed)
        appliedSequence.store(sequence, ordering: .releasing)
        return produced
    }

    private func applyPendingCommands() {
        let anchor = pendingAnchor.exchange(Self.noCommand, ordering: .acquiringAndReleasing)
        if anchor >= 0 {
            anchorPos = anchor
            readPos = anchor
            phase = .filling
            fadeRemaining = 0
            fadeFromPos = -1
        }

        let newDelay = pendingDelay.exchange(Self.noCommand, ordering: .acquiringAndReleasing)
        let reanchor = pendingReanchor.exchange(false, ordering: .acquiringAndReleasing)
        if newDelay >= 0 || reanchor {
            applyDelay(newDelay >= 0 ? newDelay : delayFrames, reanchor: reanchor)
        }
    }

    private func applyDelay(_ newDelay: Int, reanchor: Bool) {
        switch phase {
        case .idle, .filling:
            delayFrames = newDelay

        case .playing:
            let writePos = ring.writePosition
            let oldest = oldestReadable(writePos: writePos)
            let target = reanchor ? writePos - newDelay : readPos - (newDelay - delayFrames)
            delayFrames = newDelay
            if target < oldest {
                // Not enough history yet: hold at the oldest frame until the delay is reachable.
                readPos = oldest
                phase = .filling
                fadeRemaining = 0
                fadeFromPos = -1
            } else {
                beginFade(from: readPos)
                readPos = min(target, writePos)
            }
        }
    }

    private func oldestReadable(writePos: Int) -> Int {
        max(anchorPos, writePos - ring.capacity + guardFrames)
    }

    private func beginFade(from position: Int) {
        fadeFromPos = position
        fadeRemaining = crossfadeFrames
    }

    private func renderPlaying(into output: UnsafeMutablePointer<Float>, frameCount: Int, writePos: Int) -> Bool {
        if pauseFlag.load(ordering: .relaxed) {
            output.update(repeating: 0, count: frameCount)
            registerStall(frames: frameCount, writePos: writePos)
            return false
        }

        // If the writer lapped us (only possible if rendering stalled for a very
        // long time), jump forward to the oldest readable frame.
        let oldest = oldestReadable(writePos: writePos)
        if readPos < oldest {
            delayFrames -= oldest - readPos
            readPos = oldest
            fadeRemaining = 0
        }

        var index = 0
        while index < frameCount && readPos < writePos {
            var sample = ring.sample(at: readPos)
            if fadeRemaining > 0 {
                // Equal-power crossfade from the previous read position (or silence when fadeFromPos < 0).
                let progress = 1 - Float(fadeRemaining) / Float(crossfadeFrames)
                let angle = progress * (Float.pi / 2)
                let previous: Float = (fadeFromPos >= 0 && fadeFromPos < writePos) ? ring.sample(at: fadeFromPos) : 0
                sample = sample * sin(angle) + previous * cos(angle)
                fadeFromPos += 1
                fadeRemaining -= 1
            }
            output[index] = sample
            readPos += 1
            index += 1
        }

        if index < frameCount {
            // Underrun: the source hasn't delivered this far yet. Wait (silence)
            // rather than skipping, which grows the delay by the stalled frames.
            (output + index).update(repeating: 0, count: frameCount - index)
            registerStall(frames: frameCount - index, writePos: writePos)
        }
        return index > 0
    }

    private func registerStall(frames: Int, writePos: Int) {
        delayFrames += frames
        if delayFrames > maxDelayFrames {
            // Cap the delay by dropping the oldest audio.
            readPos = min(readPos + (delayFrames - maxDelayFrames), writePos)
            delayFrames = maxDelayFrames
        }
    }
}
