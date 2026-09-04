import Foundation
import Synchronization

/// Lock-free single-producer / single-consumer ring buffer of mono Float32 samples.
///
/// Positions are absolute frame counters that only ever increase, so a reader can
/// ask for "the frame written N frames ago" without caring about wrap-around.
/// The producer appends at `writePosition`; a consumer may read any position in
/// the window `[writePosition - capacity + guard, writePosition)`.
///
/// Thread-safety: exactly one writer thread and one reader thread. Neither side
/// allocates, locks, or blocks, so `sample(at:)` is safe on the audio render thread.
final class PCMRingBuffer: @unchecked Sendable {

    /// Number of frames the buffer can hold. Always a power of two so that
    /// absolute positions map to storage indices with a mask instead of a modulo.
    let capacity: Int

    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let position = Atomic<Int>(0)

    /// - Parameter minimumCapacity: rounded up to the next power of two.
    init(minimumCapacity: Int) {
        precondition(minimumCapacity > 0, "ring buffer needs a positive capacity")
        var size = 1
        while size < minimumCapacity { size <<= 1 }
        capacity = size
        mask = size - 1
        storage = UnsafeMutablePointer<Float>.allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Absolute position of the next frame to be written, i.e. total frames written so far.
    var writePosition: Int {
        position.load(ordering: .acquiring)
    }

    /// Oldest absolute position that is still safe to read.
    ///
    /// `guardFrames` of headroom keeps a reader clear of the region the producer
    /// may be overwriting right now.
    func oldestReadablePosition(guardFrames: Int) -> Int {
        max(0, writePosition - capacity + guardFrames)
    }

    /// Appends `count` frames. If `count` exceeds the capacity only the newest
    /// `capacity` frames survive, but `writePosition` still advances by `count`
    /// so absolute positions stay truthful.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        let start = position.load(ordering: .relaxed)
        var source = samples
        var frames = count
        var first = start
        if frames > capacity {
            let dropped = frames - capacity
            source += dropped
            first += dropped
            frames = capacity
        }
        let head = first & mask
        let firstRun = min(frames, capacity - head)
        (storage + head).update(from: source, count: firstRun)
        if firstRun < frames {
            storage.update(from: source + firstRun, count: frames - firstRun)
        }
        position.store(start + count, ordering: .releasing)
    }

    func write(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            write(base, count: buffer.count)
        }
    }

    /// The sample stored at an absolute position. The caller is responsible for
    /// keeping `absolutePosition` inside the readable window.
    @inline(__always)
    func sample(at absolutePosition: Int) -> Float {
        storage[absolutePosition & mask]
    }
}
