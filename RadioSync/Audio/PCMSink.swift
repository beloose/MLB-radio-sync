import AVFoundation
import Accelerate

/// Accepts PCM buffers in any Float32 layout (mono/stereo, interleaved or not,
/// any sample rate), converts them to the ring buffer's mono format, and appends
/// them. This is what an `AudioSource` writes into.
///
/// Not reentrant: a given sink must be fed from one thread at a time. It is fine
/// to call from an input-node tap or a background decoding task; it is *not*
/// realtime-safe (sample-rate conversion may allocate).
final class PCMSink: @unchecked Sendable {

    let ring: PCMRingBuffer
    let sampleRate: Double
    let format: AVAudioFormat

    private var monoScratch: [Float] = []
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(ring: PCMRingBuffer, sampleRate: Double) {
        self.ring = ring
        self.sampleRate = sampleRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            preconditionFailure("could not build mono Float32 format at \(sampleRate) Hz")
        }
        self.format = format
    }

    /// Frames written to the ring so far, i.e. the ring's write position.
    var framesWritten: Int { ring.writePosition }

    func write(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, buffer.format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData else { return }

        let channelCount = Int(buffer.format.channelCount)
        let inputRate = buffer.format.sampleRate
        guard channelCount > 0, inputRate > 0 else { return }

        // Fast path: already mono at the ring's rate.
        if channelCount == 1 && inputRate == sampleRate {
            ring.write(channels[0], count: frames)
            return
        }

        if monoScratch.count < frames {
            monoScratch = [Float](repeating: 0, count: frames)
        }
        monoScratch.withUnsafeMutableBufferPointer { mono in
            guard let out = mono.baseAddress else { return }
            let stride = vDSP_Stride(buffer.stride)
            let count = vDSP_Length(frames)
            if buffer.format.isInterleaved {
                // channels[0] points at interleaved samples; walk each channel with a stride.
                vDSP_vclr(out, 1, count)
                for channel in 0..<channelCount {
                    vDSP_vadd(out, 1, channels[0] + channel, stride, out, 1, count)
                }
            } else {
                out.update(from: channels[0], count: frames)
                for channel in 1..<max(channelCount, 1) {
                    vDSP_vadd(out, 1, channels[channel], 1, out, 1, count)
                }
            }
            if channelCount > 1 {
                var scale = 1 / Float(channelCount)
                vDSP_vsmul(out, 1, &scale, out, 1, count)
            }
        }

        if inputRate == sampleRate {
            monoScratch.withUnsafeBufferPointer { mono in
                guard let base = mono.baseAddress else { return }
                ring.write(base, count: frames)
            }
            return
        }

        writeResampled(frames: frames, inputRate: inputRate)
    }

    private func writeResampled(frames: Int, inputRate: Double) {
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false) else { return }

        if converter == nil || converterInputFormat?.sampleRate != inputRate {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converterInputFormat = inputFormat
        }
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(frames) * sampleRate / inputRate) + 64),
              let inputData = input.floatChannelData else { return }

        monoScratch.withUnsafeBufferPointer { mono in
            guard let base = mono.baseAddress else { return }
            inputData[0].update(from: base, count: frames)
        }
        input.frameLength = AVAudioFrameCount(frames)

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, let outData = output.floatChannelData, output.frameLength > 0 else { return }
        ring.write(outData[0], count: Int(output.frameLength))
    }
}
