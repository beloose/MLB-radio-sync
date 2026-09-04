import AVFoundation

/// Feeds the microphone into the ring buffer. Point the phone at a physical
/// radio and the app becomes a delay line for it. Also the cheapest way to
/// exercise the whole delay engine: any sound in the room works.
@MainActor
final class MicPassthroughSource: AudioSource {

    let kind: AudioSourceKind = .microphone
    let needsMicrophone = true
    private(set) var metadata = AudioSourceMetadata(title: "Mic passthrough", subtitle: "Microphone")

    private weak var engine: AVAudioEngine?

    func start(sink: PCMSink, context: AudioSourceContext) throws {
        let input = context.engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioSourceError.noAudioInput
        }

        // The tap runs on an internal AVAudioEngine thread, not the render thread,
        // so the sink is free to resample here. iOS delivers ~100 ms buffers
        // regardless of the requested size; that only adds a constant offset.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.write(buffer)
        }
        engine = context.engine

        let route = AVAudioSession.sharedInstance().currentRoute
        metadata = AudioSourceMetadata(
            title: "Mic passthrough",
            subtitle: route.inputs.first?.portName ?? "Microphone",
            detail: String(format: "%.1f kHz · %d ch", format.sampleRate / 1000, Int(format.channelCount))
        )
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
    }
}
