import AVFoundation
import Foundation

/// Decoded PCM waiting for its turn to enter the ring. Any thread may enqueue;
/// the pacer dequeues. Buffers may be in different formats (the sink adapts).
final class PCMQueue: @unchecked Sendable {

    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    /// Frames of `buffers[0]` already handed out.
    private var headOffset = 0
    private var queued: Double = 0

    var queuedSeconds: Double {
        lock.withLock { queued }
    }

    var isEmpty: Bool {
        lock.withLock { buffers.isEmpty }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
        lock.withLock {
            buffers.append(buffer)
            queued += Double(buffer.frameLength) / buffer.format.sampleRate
        }
    }

    /// Appends `seconds` of silence in `format` (mono/stereo Float32).
    func enqueueSilence(seconds: Double, format: AVAudioFormat) {
        let frames = AVAudioFrameCount(max(0, seconds) * format.sampleRate)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames  // Freshly allocated buffers are zeroed.
        enqueue(buffer)
    }

    func removeAll() {
        lock.withLock {
            buffers.removeAll()
            headOffset = 0
            queued = 0
        }
    }

    /// Removes up to `seconds` of audio from the front, splitting a buffer at a
    /// frame boundary if needed. Returns fewer seconds if the queue runs out.
    func dequeue(seconds: Double) -> [AVAudioPCMBuffer] {
        var remaining = seconds
        var result: [AVAudioPCMBuffer] = []
        lock.withLock {
            while remaining > 0, let head = buffers.first {
                let rate = head.format.sampleRate
                let available = Int(head.frameLength) - headOffset
                let wanted = Int((remaining * rate).rounded(.up))
                if wanted >= available {
                    if headOffset == 0 {
                        result.append(head)
                    } else if let tail = Self.slice(head, from: headOffset, frames: available) {
                        result.append(tail)
                    }
                    buffers.removeFirst()
                    headOffset = 0
                    remaining -= Double(available) / rate
                    queued -= Double(available) / rate
                } else {
                    if let piece = Self.slice(head, from: headOffset, frames: wanted) {
                        result.append(piece)
                    }
                    headOffset += wanted
                    remaining -= Double(wanted) / rate
                    queued -= Double(wanted) / rate
                }
            }
            if buffers.isEmpty { queued = 0 }
        }
        return result
    }

    static func slice(_ source: AVAudioPCMBuffer, from start: Int, frames: Int) -> AVAudioPCMBuffer? {
        guard frames > 0, let data = source.floatChannelData,
              let piece = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(frames)),
              let target = piece.floatChannelData else { return nil }
        let channels = Int(source.format.channelCount)
        if source.format.isInterleaved {
            target[0].update(from: data[0] + start * channels, count: frames * channels)
        } else {
            for channel in 0..<channels {
                target[channel].update(from: data[channel] + start, count: frames)
            }
        }
        piece.frameLength = AVAudioFrameCount(frames)
        return piece
    }

    /// Joins consecutive buffers of one format into a single buffer.
    static func concatenate(_ pieces: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = pieces.first else { return nil }
        if pieces.count == 1 { return first }
        guard !first.format.isInterleaved, pieces.allSatisfy({ $0.format == first.format }) else { return nil }
        let total = pieces.reduce(0) { $0 + Int($1.frameLength) }
        guard let merged = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(total)),
              let target = merged.floatChannelData else { return nil }
        let channels = Int(first.format.channelCount)
        var offset = 0
        for piece in pieces {
            guard let data = piece.floatChannelData else { continue }
            let frames = Int(piece.frameLength)
            for channel in 0..<channels {
                (target[channel] + offset).update(from: data[channel], count: frames)
            }
            offset += frames
        }
        merged.frameLength = AVAudioFrameCount(offset)
        return merged
    }
}

/// Moves audio from a `PCMQueue` into the `PCMSink` at exactly real-time rate,
/// so the ring's write position advances like a live capture and the delay
/// reader's accounting stays exact. Whatever is queued beyond the schedule is
/// the cushion that absorbs network jitter.
///
/// Schedule: `begin(burstSeconds:)` writes the burst as one ring write and
/// starts the clock; from then on the writer owes `burst + elapsed` seconds. If
/// the queue runs dry the writer falls behind and catches up when audio
/// returns, which matches the reader growing the delay during the stall.
/// `resync()` instead forgives the shortfall with silence when the streamer
/// knows content was lost for good.
final class PacedSinkWriter: @unchecked Sendable {

    struct Stats: Equatable, Sendable {
        /// Audio queued beyond what the schedule has consumed.
        var cushionSeconds: Double = 0
        /// How far the writer is behind schedule (audio owed but not available).
        var shortfallSeconds: Double = 0
        var hasBegun = false
        var writtenSeconds: Double = 0
    }

    static let tick: Duration = .milliseconds(100)
    static let maxSilenceFill: Double = 120

    private let queue: PCMQueue
    private let sink: PCMSink
    private let lock = NSLock()
    private var clockStart: ContinuousClock.Instant?
    private var burstSeconds: Double = 0
    private var writtenSeconds: Double = 0
    private var resyncRequested = false
    private var task: Task<Void, Never>?

    init(queue: PCMQueue, sink: PCMSink) {
        self.queue = queue
        self.sink = sink
    }

    var stats: Stats {
        lock.withLock {
            var stats = Stats(cushionSeconds: queue.queuedSeconds, hasBegun: clockStart != nil, writtenSeconds: writtenSeconds)
            if let clockStart {
                stats.shortfallSeconds = max(0, burstSeconds + Self.seconds(since: clockStart) - writtenSeconds)
            }
            return stats
        }
    }

    func start() {
        task?.cancel()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var next = ContinuousClock.now
            while !Task.isCancelled {
                next += Self.tick
                try? await Task.sleep(until: next, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                self.pump()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Writes up to `burstSeconds` of already-queued audio immediately (as one
    /// ring write, so the reader sees it land at once) and starts the clock.
    func begin(burstSeconds: Double) {
        let pieces = queue.dequeue(seconds: max(0, burstSeconds))
        var written = 0.0
        if let merged = PCMQueue.concatenate(pieces) {
            sink.write(merged)
            written = Double(merged.frameLength) / merged.format.sampleRate
        } else {
            for piece in pieces {
                sink.write(piece)
                written += Double(piece.frameLength) / piece.format.sampleRate
            }
        }
        lock.withLock {
            clockStart = .now
            self.burstSeconds = written
            writtenSeconds = written
            resyncRequested = false
        }
    }

    /// The content timeline broke (reconnect, segments gone). Fill what the
    /// schedule is owed with silence so the next audio plays as fresh content.
    func resync() {
        lock.withLock { resyncRequested = true }
    }

    // MARK: Private

    private func pump() {
        var owed = 0.0
        var fillSilence = 0.0
        lock.withLock {
            guard let clockStart else { return }
            let scheduled = burstSeconds + Self.seconds(since: clockStart)
            owed = scheduled - writtenSeconds
            if resyncRequested {
                resyncRequested = false
                if owed > 0.02 {
                    fillSilence = min(owed, Self.maxSilenceFill)
                    writtenSeconds = scheduled
                    owed = 0
                }
            }
        }
        if fillSilence > 0 {
            let frames = AVAudioFrameCount(fillSilence * sink.sampleRate)
            if let silence = AVAudioPCMBuffer(pcmFormat: sink.format, frameCapacity: frames) {
                silence.frameLength = frames
                sink.write(silence)
            }
        }
        guard owed > 0.0005 else { return }
        var written = 0.0
        for piece in queue.dequeue(seconds: owed) {
            sink.write(piece)
            written += Double(piece.frameLength) / piece.format.sampleRate
        }
        if written > 0 {
            lock.withLock { writtenSeconds += written }
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        let (seconds, attoseconds) = elapsed.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
