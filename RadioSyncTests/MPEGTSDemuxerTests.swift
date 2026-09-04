import XCTest
@testable import RadioSync

final class MPEGTSDemuxerTests: XCTestCase {

    // MARK: Packet builders

    private func packet(pid: Int, payloadStart: Bool, continuity: UInt8, payload: [UInt8], adaptation: [UInt8]? = nil) -> [UInt8] {
        var bytes: [UInt8] = [0x47, UInt8((payloadStart ? 0x40 : 0) | ((pid >> 8) & 0x1F)), UInt8(pid & 0xFF)]
        var body: [UInt8] = []
        if let adaptation {
            body.append(UInt8(adaptation.count))
            body += adaptation
        }
        body += payload
        let afc: UInt8 = adaptation != nil ? 0x30 : 0x10
        bytes.append(afc | (continuity & 0x0F))
        precondition(body.count <= 184, "payload too large")
        bytes += body
        bytes += [UInt8](repeating: 0xFF, count: 184 - body.count)
        return bytes
    }

    private func section(tableID: UInt8, body: [UInt8]) -> [UInt8] {
        // pointer_field, table_id, section_syntax(1) + length(12), then body (which includes the 5 header bytes) + 4 CRC bytes.
        let length = body.count + 4
        return [0x00, tableID, 0xB0 | UInt8((length >> 8) & 0x0F), UInt8(length & 0xFF)] + body + [0xDE, 0xAD, 0xBE, 0xEF]
    }

    private func pat(pmtPID: Int) -> [UInt8] {
        let header: [UInt8] = [0x00, 0x01, 0xC1, 0x00, 0x00]  // tsid, version/current, section number, last section
        let program: [UInt8] = [0x00, 0x01, UInt8(0xE0 | (pmtPID >> 8)), UInt8(pmtPID & 0xFF)]
        return packet(pid: 0, payloadStart: true, continuity: 0, payload: section(tableID: 0, body: header + program))
    }

    private func pmt(pid: Int, streams: [(type: UInt8, pid: Int)]) -> [UInt8] {
        var body: [UInt8] = [0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x00, 0xF0, 0x00]  // program number, version, sections, PCR PID, program info length 0
        for stream in streams {
            body += [stream.type, UInt8(0xE0 | (stream.pid >> 8)), UInt8(stream.pid & 0xFF), 0xF0, 0x00]
        }
        return packet(pid: pid, payloadStart: true, continuity: 0, payload: section(tableID: 2, body: body))
    }

    /// PES header with an explicit packet length covering `payloadLength` bytes after the header (0 = unbounded).
    private func pesHeader(streamID: UInt8, headerData: [UInt8], payloadLength: Int = 0) -> [UInt8] {
        let length = payloadLength > 0 ? 3 + headerData.count + payloadLength : 0
        return [0x00, 0x00, 0x01, streamID, UInt8(length >> 8), UInt8(length & 0xFF), 0x80, 0x80, UInt8(headerData.count)] + headerData
    }

    // MARK: Tests

    func testExtractsAACElementaryStreamAcrossPackets() throws {
        let audioPID = 0x101
        let elementary = [UInt8]((0..<400).map { UInt8($0 & 0xFF) })
        let pes = pesHeader(streamID: 0xC0, headerData: [UInt8](repeating: 0x11, count: 5), payloadLength: elementary.count)  // 5-byte PTS
        var stream: [UInt8] = []
        stream += pat(pmtPID: 0x100)
        stream += pmt(pid: 0x100, streams: [(0x1B, 0x102), (0x0F, audioPID)])  // video first, then AAC
        // First packet: PES header + first slice; 184 - 14 = 170 bytes of payload.
        stream += packet(pid: audioPID, payloadStart: true, continuity: 0, payload: pes + Array(elementary[0..<170]))
        // Second packet: with an adaptation field of 4 bytes (flags + 3 stuffing) → 184 - 5 = 179 available.
        stream += packet(pid: audioPID, payloadStart: false, continuity: 1, payload: Array(elementary[170..<349]), adaptation: [0x00, 0xFF, 0xFF, 0xFF])
        // A video packet that must be ignored.
        stream += packet(pid: 0x102, payloadStart: true, continuity: 0, payload: pesHeader(streamID: 0xE0, headerData: []) + [1, 2, 3])
        // Last audio slice.
        stream += packet(pid: audioPID, payloadStart: false, continuity: 2, payload: Array(elementary[349..<400]))

        var demuxer = MPEGTSDemuxer()
        XCTAssertTrue(MPEGTSDemuxer.looksLikeTransportStream(Data(stream)))
        let output = try demuxer.demux(Data(stream))
        XCTAssertEqual(demuxer.codec, .aacADTS)
        XCTAssertEqual([UInt8](output), elementary)
    }

    func testCarriesPartialPacketAcrossCalls() throws {
        let audioPID = 0x44
        let payload = [UInt8](repeating: 0xAB, count: 100)
        var stream: [UInt8] = []
        stream += pat(pmtPID: 0x20)
        stream += pmt(pid: 0x20, streams: [(0x03, audioPID)])
        stream += packet(pid: audioPID, payloadStart: true, continuity: 0, payload: pesHeader(streamID: 0xC0, headerData: [], payloadLength: payload.count) + payload)

        var demuxer = MPEGTSDemuxer()
        let split = 188 * 2 + 50
        var output = try demuxer.demux(Data(stream[0..<split]))
        output += try demuxer.demux(Data(stream[split...]))
        XCTAssertEqual(demuxer.codec, .mpegAudio)
        XCTAssertEqual([UInt8](output), payload)
    }

    func testUnsupportedAudioIsReported() {
        var stream: [UInt8] = []
        stream += pat(pmtPID: 0x20)
        stream += pmt(pid: 0x20, streams: [(0x81, 0x50)])  // AC-3 only
        var demuxer = MPEGTSDemuxer()
        XCTAssertThrowsError(try demuxer.demux(Data(stream))) { error in
            guard case MPEGTSDemuxer.DemuxError.unsupportedAudio = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testResyncsAfterGarbage() throws {
        let audioPID = 0x101
        var stream: [UInt8] = [0x00, 0x01, 0x02]  // junk before the first sync byte
        stream += pat(pmtPID: 0x100)
        stream += pmt(pid: 0x100, streams: [(0x0F, audioPID)])
        // Unbounded PES length with adaptation-field stuffing, the way real muxers pad short packets.
        stream += packet(pid: audioPID, payloadStart: true, continuity: 0, payload: pesHeader(streamID: 0xC0, headerData: []) + [9, 8, 7], adaptation: [0x00] + [UInt8](repeating: 0xFF, count: 184 - 1 - 1 - 9 - 3))
        var demuxer = MPEGTSDemuxer()
        let output = try demuxer.demux(Data(stream))
        XCTAssertEqual([UInt8](output), [9, 8, 7])
    }
}
