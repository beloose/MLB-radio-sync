import XCTest
@testable import RadioSync

final class PCMRingBufferTests: XCTestCase {

    func testCapacityRoundsUpToPowerOfTwo() {
        XCTAssertEqual(PCMRingBuffer(minimumCapacity: 1000).capacity, 1024)
        XCTAssertEqual(PCMRingBuffer(minimumCapacity: 1024).capacity, 1024)
        XCTAssertEqual(PCMRingBuffer(minimumCapacity: 1).capacity, 1)
    }

    func testWritesAdvancePositionAndWrapAround() {
        let ring = PCMRingBuffer(minimumCapacity: 1024)
        // 5 chunks of 300 = 1500 frames, so the storage wraps once.
        var next = 0
        for _ in 0..<5 {
            let chunk = (0..<300).map { _ -> Float in
                defer { next += 1 }
                return Float(next)
            }
            ring.write(chunk)
        }
        XCTAssertEqual(ring.writePosition, 1500)
        // The newest `capacity` frames are readable; the value at position p is p.
        for position in (1500 - 1024)..<1500 {
            XCTAssertEqual(ring.sample(at: position), Float(position))
        }
        XCTAssertEqual(ring.oldestReadablePosition(guardFrames: 100), 1500 - 1024 + 100)
    }

    func testOldestReadableNeverNegative() {
        let ring = PCMRingBuffer(minimumCapacity: 64)
        ring.write([Float](repeating: 1, count: 10))
        XCTAssertEqual(ring.oldestReadablePosition(guardFrames: 8), 0)
    }

    func testOversizedWriteKeepsNewestFrames() {
        let ring = PCMRingBuffer(minimumCapacity: 64)
        ring.write((0..<200).map(Float.init))
        XCTAssertEqual(ring.writePosition, 200)
        for position in (200 - 64)..<200 {
            XCTAssertEqual(ring.sample(at: position), Float(position))
        }
    }

    func testEmptyWriteIsNoop() {
        let ring = PCMRingBuffer(minimumCapacity: 16)
        ring.write([])
        XCTAssertEqual(ring.writePosition, 0)
    }
}
