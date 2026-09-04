import AVFoundation
import AudioToolbox
import XCTest
@testable import RadioSync

final class AudioStreamDecoderTests: XCTestCase {

    /// Encodes `seconds` of a sine wave to AAC-LC and wraps each packet in an ADTS header.
    private func makeADTS(seconds: Double, sampleRate: Double = 44_100, frequency: Double = 440) throws -> Data {
        let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let aacFormat = AVAudioFormat(streamDescription: &description)!
        guard let encoder = AVAudioConverter(from: pcmFormat, to: aacFormat) else {
            throw XCTSkip("No AAC encoder available in this environment")
        }
        encoder.bitRate = 96_000

        let frames = Int(seconds * sampleRate)
        let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { pcm.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * frequency * Double(i) / sampleRate)) }

        // One call with room for every packet; the block hands over the PCM once, then signals the end.
        var consumed = false
        let packets = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: AVAudioPacketCount(frames / 1024 + 8), maximumPacketSize: 2048)
        var error: NSError?
        let status = encoder.convert(to: packets, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return pcm
        }
        if status == .error { throw error ?? NSError(domain: "test", code: -1) }
        guard let descriptions = packets.packetDescriptions, packets.packetCount > 0 else { throw XCTSkip("AAC encoder produced nothing") }

        var adts = Data()
        let sampleRateIndex: UInt8 = sampleRate == 48_000 ? 3 : 4  // 44.1 kHz → 4
        for index in 0..<Int(packets.packetCount) {
            let description = descriptions[index]
            let size = Int(description.mDataByteSize)
            let frameLength = size + 7
            // ADTS: sync, MPEG-4, no CRC; profile AAC-LC (1); channel configuration 1 (mono).
            let channelConfig = 1
            let header: [UInt8] = [
                0xFF, 0xF1,
                UInt8((1 << 6) | (Int(sampleRateIndex) << 2) | ((channelConfig >> 2) & 0x01)),
                UInt8(((channelConfig & 0x03) << 6) | ((frameLength >> 11) & 0x03)),
                UInt8((frameLength >> 3) & 0xFF),
                UInt8(((frameLength & 0x07) << 5) | 0x1F),
                0xFC,
            ]
            adts.append(contentsOf: header)
            adts.append(Data(bytes: packets.data + Int(description.mStartOffset), count: size))
        }
        return adts
    }

    func testDecodesADTSInSmallChunksWithoutLosingFrames() throws {
        let adts = try makeADTS(seconds: 2)
        XCTAssertGreaterThan(adts.count, 2_000)  // a pure sine compresses far below the nominal bit rate

        func decodeAll(chunk: Int) throws -> (frames: Int, format: String?, peak: Float) {
            let decoder = try AudioStreamDecoder(fileTypeHint: kAudioFileAAC_ADTSType)
            var frames = 0
            var peak: Float = 0
            var offset = 0
            while offset < adts.count {
                let end = min(offset + chunk, adts.count)
                for buffer in try decoder.decode(adts[offset..<end]) {
                    frames += Int(buffer.frameLength)
                    for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![0][i])) }
                }
                offset = end
            }
            return (frames, decoder.formatDescription, peak)
        }

        let whole = try decodeAll(chunk: adts.count)
        let small = try decodeAll(chunk: 700)
        let tiny = try decodeAll(chunk: 64)
        XCTAssertEqual(whole.format, "AAC 44.1 kHz mono")
        XCTAssertEqual(small.frames, whole.frames, "chunking must not drop packets")
        XCTAssertEqual(tiny.frames, whole.frames)
        // 2 s of audio, allowing for the encoder's priming and the decoder holding back the last packet.
        XCTAssertGreaterThan(whole.frames, Int(44_100 * 1.8))
        XCTAssertLessThan(whole.frames, Int(44_100 * 2.2))
        XCTAssertEqual(whole.peak, 0.5, accuracy: 0.08)
    }

    func testStripsLeadingID3TagsAndDetectsContainers() {
        var tagged = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC])  // ID3v2.4, size 3
        tagged.append(contentsOf: [0xFF, 0xF1, 0x50, 0x80])  // ADTS sync
        let stripped = SegmentDecoder.strippingID3(tagged)
        XCTAssertEqual([UInt8](stripped), [0xFF, 0xF1, 0x50, 0x80])
        XCTAssertEqual(SegmentDecoder.sniffElementaryType(stripped), kAudioFileAAC_ADTSType)
        XCTAssertEqual(SegmentDecoder.detectContainer(tagged), .packedAudio)

        let mp3 = Data([0xFF, 0xFB, 0x90, 0x00])
        XCTAssertEqual(SegmentDecoder.sniffElementaryType(mp3), kAudioFileMP3Type)

        var ts = Data(repeating: 0, count: 188 * 2)
        ts[0] = 0x47
        ts[188] = 0x47
        XCTAssertEqual(SegmentDecoder.detectContainer(ts), .transportStream)

        let fmp4 = Data([0x00, 0x00, 0x00, 0x18] + Array("ftypiso5".utf8) + [0, 0, 0, 0])
        XCTAssertEqual(SegmentDecoder.detectContainer(fmp4), .fragmentedMP4)
    }

    func testAES128RoundTrip() throws {
        let key = Data((0..<16).map { UInt8($0) })
        let iv = Data(repeating: 7, count: 16)
        let plain = Data("sixteen byte msg plus a tail".utf8)
        // AES-128-CBC with PKCS7 padding of `plain`, computed with:
        // printf 'sixteen byte msg plus a tail' | openssl enc -aes-128-cbc -K 000102030405060708090a0b0c0d0e0f -iv 07070707070707070707070707070707 | base64
        let cipher = Data(base64Encoded: "HLs1MTgdFV7rD32mNLuUGFOgMvUERuksdb7t8/fvEmA=")!
        XCTAssertEqual(try StreamPipeline.decryptAES128CBC(cipher, key: key, iv: iv), plain)
    }
}
