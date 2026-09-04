import Foundation

/// Pulls the audio elementary stream out of MPEG-2 transport stream segments.
///
/// Finds the first program's PMT, picks its audio PID (AAC preferred, then
/// MPEG audio), strips PES headers, and hands back the raw elementary stream
/// bytes, which are ADTS frames for AAC or MPEG audio frames for MP2/MP3.
/// State (PIDs, partial packets) carries across calls so a segment boundary
/// mid-stream is not a problem; call `reset()` at a discontinuity.
struct MPEGTSDemuxer {

    enum Codec: Equatable {
        case aacADTS
        case mpegAudio
        case unsupported(streamType: UInt8)

        var description: String {
            switch self {
            case .aacADTS: "AAC"
            case .mpegAudio: "MPEG audio"
            case .unsupported(let type): String(format: "stream type 0x%02X", type)
            }
        }
    }

    enum DemuxError: LocalizedError {
        case unsupportedAudio(Codec)
        case noAudioTrack

        var errorDescription: String? {
            switch self {
            case .unsupportedAudio(let codec): "The stream's audio codec (\(codec.description)) isn't supported."
            case .noAudioTrack: "The transport stream has no audio track."
            }
        }
    }

    static let packetSize = 188

    private(set) var codec: Codec?
    private var pmtPID: Int?
    private var audioPID: Int?
    private var carry = Data()
    private var sawPMT = false
    /// Payload bytes left in the current PES packet when its length is known (0 = unbounded).
    private var pesRemaining = 0

    /// True if `data` looks like the start of a transport stream.
    static func looksLikeTransportStream(_ data: Data) -> Bool {
        guard data.count >= packetSize + 1 else { return data.first == 0x47 }
        return data[data.startIndex] == 0x47 && data[data.startIndex + packetSize] == 0x47
    }

    mutating func reset() {
        codec = nil
        pmtPID = nil
        audioPID = nil
        carry.removeAll()
        sawPMT = false
        pesRemaining = 0
    }

    /// Demuxes `data`, returning the elementary stream bytes it contained.
    mutating func demux(_ data: Data) throws -> Data {
        var input: Data
        if carry.isEmpty {
            input = data
        } else {
            input = carry
            input.append(data)
            carry.removeAll()
        }
        var output = Data(capacity: input.count)
        var error: DemuxError?

        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            var offset = 0
            while offset + Self.packetSize <= count {
                if base[offset] != 0x47 {
                    // Lost sync: scan forward for the next sync byte.
                    offset += 1
                    continue
                }
                if let failure = handlePacket(base + offset, into: &output) {
                    error = failure
                    return
                }
                offset += Self.packetSize
            }
            if offset < count {
                carry = Data(bytes: base + offset, count: count - offset)
            }
        }

        if let error { throw error }
        return output
    }

    // MARK: Packets

    private mutating func handlePacket(_ packet: UnsafePointer<UInt8>, into output: inout Data) -> DemuxError? {
        let transportError = packet[1] & 0x80 != 0
        let payloadStart = packet[1] & 0x40 != 0
        let pid = (Int(packet[1] & 0x1F) << 8) | Int(packet[2])
        let adaptationControl = (packet[3] >> 4) & 0x03
        guard !transportError, adaptationControl & 0x01 != 0 else { return nil }

        var payloadOffset = 4
        if adaptationControl & 0x02 != 0 {
            payloadOffset += 1 + Int(packet[4])
        }
        guard payloadOffset < Self.packetSize else { return nil }
        let payload = UnsafeBufferPointer(start: packet + payloadOffset, count: Self.packetSize - payloadOffset)

        if pid == 0 {
            if pmtPID == nil, payloadStart { parsePAT(payload) }
        } else if pid == pmtPID {
            if !sawPMT, payloadStart { return parsePMT(payload) }
        } else if pid == audioPID {
            appendPES(payload, payloadStart: payloadStart, into: &output)
        }
        return nil
    }

    private func sectionStart(_ payload: UnsafeBufferPointer<UInt8>) -> Int? {
        // Payload begins with pointer_field when payload_unit_start_indicator is set.
        guard payload.count > 1 else { return nil }
        let start = 1 + Int(payload[0])
        return start < payload.count ? start : nil
    }

    private mutating func parsePAT(_ payload: UnsafeBufferPointer<UInt8>) {
        guard let start = sectionStart(payload), start + 8 <= payload.count, payload[start] == 0x00 else { return }
        let sectionLength = (Int(payload[start + 1] & 0x0F) << 8) | Int(payload[start + 2])
        let end = min(start + 3 + sectionLength - 4, payload.count)  // minus CRC
        var index = start + 8
        while index + 4 <= end {
            let programNumber = (Int(payload[index]) << 8) | Int(payload[index + 1])
            let pid = (Int(payload[index + 2] & 0x1F) << 8) | Int(payload[index + 3])
            if programNumber != 0 {
                pmtPID = pid
                return
            }
            index += 4
        }
    }

    private mutating func parsePMT(_ payload: UnsafeBufferPointer<UInt8>) -> DemuxError? {
        guard let start = sectionStart(payload), start + 12 <= payload.count, payload[start] == 0x02 else { return nil }
        let sectionLength = (Int(payload[start + 1] & 0x0F) << 8) | Int(payload[start + 2])
        let end = min(start + 3 + sectionLength - 4, payload.count)
        let programInfoLength = (Int(payload[start + 10] & 0x0F) << 8) | Int(payload[start + 11])
        var index = start + 12 + programInfoLength

        var aac: Int?
        var mpeg: Int?
        var other: (pid: Int, type: UInt8)?
        while index + 5 <= end {
            let streamType = payload[index]
            let pid = (Int(payload[index + 1] & 0x1F) << 8) | Int(payload[index + 2])
            let infoLength = (Int(payload[index + 3] & 0x0F) << 8) | Int(payload[index + 4])
            switch streamType {
            case 0x0F: if aac == nil { aac = pid }
            case 0x03, 0x04: if mpeg == nil { mpeg = pid }
            case 0x11, 0x81, 0x87, 0x1C, 0x06: if other == nil { other = (pid, streamType) }
            default: break
            }
            index += 5 + infoLength
        }
        sawPMT = true

        if let aac {
            audioPID = aac
            codec = .aacADTS
        } else if let mpeg {
            audioPID = mpeg
            codec = .mpegAudio
        } else if let other {
            codec = .unsupported(streamType: other.type)
            return .unsupportedAudio(.unsupported(streamType: other.type))
        } else {
            return .noAudioTrack
        }
        return nil
    }

    private mutating func appendPES(_ payload: UnsafeBufferPointer<UInt8>, payloadStart: Bool, into output: inout Data) {
        guard let base = payload.baseAddress else { return }
        var offset = 0
        if payloadStart {
            // PES header: 00 00 01 stream_id length(2) flags(2) header_data_length(1)
            guard payload.count >= 9, payload[0] == 0, payload[1] == 0, payload[2] == 1 else { return }
            let streamID = payload[3]
            let pesLength = (Int(payload[4]) << 8) | Int(payload[5])
            let hasOptionalHeader = (0xC0...0xEF).contains(streamID) || streamID == 0xBD || streamID == 0xFD
            if hasOptionalHeader {
                let headerLength = Int(payload[8])
                offset = 9 + headerLength
                pesRemaining = pesLength > 0 ? max(0, pesLength - 3 - headerLength) : 0
            } else {
                offset = 6
                pesRemaining = pesLength
            }
            guard offset <= payload.count else { return }
            if pesLength == 0 { pesRemaining = 0 }
        }
        var count = payload.count - offset
        if pesRemaining > 0 {
            count = min(count, pesRemaining)
            pesRemaining -= count
        }
        guard count > 0 else { return }
        output.append(base + offset, count: count)
    }
}
