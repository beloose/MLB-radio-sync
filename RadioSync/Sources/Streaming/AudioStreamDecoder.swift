import AVFoundation
import AudioToolbox

/// Decodes a compressed audio byte stream (ADTS AAC, MP3/MP2, or fragmented
/// MP4) to Float32 PCM as bytes arrive.
///
/// `AudioFileStream` parses the container and hands back packets; one
/// `AVAudioConverter` decodes them. Both live for the whole stream so segment
/// boundaries are seamless; make a new decoder at a discontinuity.
///
/// Feed from one thread at a time. Output buffers are non-interleaved Float32
/// at the stream's own sample rate and channel count; `PCMSink` adapts them.
final class AudioStreamDecoder {

    enum DecodeError: LocalizedError {
        case openFailed(OSStatus)
        case parseFailed(OSStatus)
        case unsupportedFormat(String)
        case converterFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let status): "Couldn't open the audio parser (\(status))."
            case .parseFailed(let status): "Couldn't parse the audio stream (\(status))."
            case .unsupportedFormat(let what): "The audio format isn't supported (\(what))."
            case .converterFailed(let what): "The audio decoder failed: \(what)"
            }
        }
    }

    /// Codec name and rate once the parser has seen enough of the stream, e.g. "AAC 44.1 kHz stereo".
    private(set) var formatDescription: String?
    private(set) var inputFormat: AVAudioFormat?
    private(set) var outputFormat: AVAudioFormat?
    /// Frames decoded so far, in the stream's sample rate.
    private(set) var framesDecoded = 0

    private var streamID: AudioFileStreamID?
    private var converter: AVAudioConverter?
    private var decoded: [AVAudioPCMBuffer] = []
    private var pendingError: DecodeError?
    private var framesPerPacket: Int = 1024

    init(fileTypeHint: AudioFileTypeID = 0) throws {
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        var stream: AudioFileStreamID?
        let status = AudioFileStreamOpen(selfPointer, { clientData, streamID, propertyID, _ in
            let decoder = Unmanaged<AudioStreamDecoder>.fromOpaque(clientData).takeUnretainedValue()
            decoder.handleProperty(propertyID, stream: streamID)
        }, { clientData, byteCount, packetCount, bytes, descriptions in
            let decoder = Unmanaged<AudioStreamDecoder>.fromOpaque(clientData).takeUnretainedValue()
            decoder.handlePackets(byteCount: byteCount, packetCount: packetCount, bytes: bytes, descriptions: descriptions)
        }, fileTypeHint, &stream)
        guard status == noErr, let stream else { throw DecodeError.openFailed(status) }
        streamID = stream
    }

    deinit {
        if let streamID { AudioFileStreamClose(streamID) }
    }

    /// Parses `data` and returns whatever PCM it produced (possibly nothing yet
    /// while the parser is still identifying the format).
    func decode(_ data: Data) throws -> [AVAudioPCMBuffer] {
        guard let streamID, !data.isEmpty else { return [] }
        decoded.removeAll(keepingCapacity: true)
        pendingError = nil
        let status = data.withUnsafeBytes { raw -> OSStatus in
            AudioFileStreamParseBytes(streamID, UInt32(raw.count), raw.baseAddress, [])
        }
        if let pendingError { throw pendingError }
        guard status == noErr else { throw DecodeError.parseFailed(status) }
        let result = decoded
        decoded.removeAll(keepingCapacity: true)
        return result
    }

    // MARK: Parser callbacks

    private func handleProperty(_ propertyID: AudioFileStreamPropertyID, stream: AudioFileStreamID) {
        guard propertyID == kAudioFileStreamProperty_ReadyToProducePackets else { return }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &asbd) == noErr else {
            pendingError = .unsupportedFormat("no data format")
            return
        }
        // Prefer the playable entry of the format list (e.g. HE-AAC over its AAC-LC core).
        var listSize: UInt32 = 0
        var writable: DarwinBoolean = false
        if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_FormatList, &listSize, &writable) == noErr, listSize > 0 {
            let count = Int(listSize) / MemoryLayout<AudioFormatListItem>.size
            var list = [AudioFormatListItem](repeating: AudioFormatListItem(), count: count)
            if AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_FormatList, &listSize, &list) == noErr, count > 0 {
                var index: UInt32 = 0
                var indexSize = UInt32(MemoryLayout<UInt32>.size)
                let status = AudioFormatGetProperty(kAudioFormatProperty_FirstPlayableFormatFromList, listSize, &list, &indexSize, &index)
                let chosen = (status == noErr && Int(index) < count) ? list[Int(index)].mASBD : list[0].mASBD
                if chosen.mSampleRate > 0, chosen.mChannelsPerFrame > 0 { asbd = chosen }
            }
        }
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            pendingError = .unsupportedFormat("unknown sample rate")
            return
        }

        var magicCookie: Data?
        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable) == noErr, cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookie) == noErr {
                magicCookie = Data(cookie)
            }
        }

        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else {
            pendingError = .unsupportedFormat(Self.codecName(for: asbd.mFormatID))
            return
        }
        if let magicCookie { converter.magicCookie = magicCookie }
        framesPerPacket = asbd.mFramesPerPacket > 0 ? Int(asbd.mFramesPerPacket) : 2048
        self.converter = converter
        inputFormat = input
        outputFormat = output
        formatDescription = String(
            format: "%@ %.1f kHz %@",
            Self.codecName(for: asbd.mFormatID),
            asbd.mSampleRate / 1000,
            asbd.mChannelsPerFrame == 1 ? "mono" : (asbd.mChannelsPerFrame == 2 ? "stereo" : "\(asbd.mChannelsPerFrame) ch")
        )
    }

    private func handlePackets(byteCount: UInt32, packetCount: UInt32, bytes: UnsafeRawPointer, descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let converter, let inputFormat, let outputFormat, packetCount > 0, pendingError == nil else { return }

        let packets = Int(packetCount)
        // The byte range can be larger than the sum of the packets (ADTS headers
        // sit between them and the descriptions point past them), so size the
        // buffer to hold the whole range, not just the largest packet.
        var maxPacketSize = (Int(byteCount) + packets - 1) / packets
        if let descriptions {
            for index in 0..<packets { maxPacketSize = max(maxPacketSize, Int(descriptions[index].mDataByteSize)) }
        }
        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: AVAudioPacketCount(packets), maximumPacketSize: max(maxPacketSize, 1))
        guard Int(byteCount) <= Int(compressed.byteCapacity) else {
            pendingError = .converterFailed("packet buffer too small (\(byteCount) > \(compressed.byteCapacity))")
            return
        }
        compressed.data.copyMemory(from: bytes, byteCount: Int(byteCount))
        compressed.byteLength = byteCount
        compressed.packetCount = packetCount
        if let descriptions, let target = compressed.packetDescriptions {
            target.update(from: descriptions, count: packets)
        }

        var handedOver = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if handedOver {
                status.pointee = .noDataNow
                return nil
            }
            handedOver = true
            status.pointee = .haveData
            return compressed
        }

        let capacity = AVAudioFrameCount(packets * framesPerPacket + 4096)
        while true {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            let status = converter.convert(to: pcm, error: &error, withInputFrom: inputBlock)
            if pcm.frameLength > 0 {
                framesDecoded += Int(pcm.frameLength)
                decoded.append(pcm)
            }
            switch status {
            case .haveData:
                continue  // Output filled up; there may be more.
            case .inputRanDry, .endOfStream:
                return
            case .error:
                pendingError = .converterFailed(error?.localizedDescription ?? "unknown error")
                return
            @unknown default:
                return
            }
        }
    }

    static func codecName(for formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatMPEG4AAC_HE: return "HE-AAC"
        case kAudioFormatMPEG4AAC_HE_V2: return "HE-AAC v2"
        case kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR, kAudioFormatMPEG4AAC_ELD_V2: return "AAC-LD"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatMPEGLayer2: return "MP2"
        case kAudioFormatMPEGLayer1: return "MP1"
        case kAudioFormatAC3: return "AC-3"
        case kAudioFormatEnhancedAC3: return "E-AC-3"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatAppleLossless: return "ALAC"
        default:
            var raw = formatID.bigEndian
            let chars = withUnsafeBytes(of: &raw) { Array($0) }
            let text = String(bytes: chars, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
            return text.isEmpty ? String(format: "0x%08X", formatID) : text
        }
    }
}
