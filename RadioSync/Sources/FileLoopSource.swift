import AVFoundation

/// "File mode" testing hook: loops an audio file into the ring buffer in real
/// time, so the delay engine can be developed without a live game or a mic.
@MainActor
final class FileLoopSource: AudioSource {

    let kind: AudioSourceKind = .fileLoop
    let needsMicrophone = false
    let restartsWithEngine = false
    private(set) var metadata: AudioSourceMetadata

    private let url: URL
    private var task: Task<Void, Never>?

    init(url: URL, name: String) {
        self.url = url
        metadata = AudioSourceMetadata(title: name, subtitle: url.lastPathComponent)
    }

    func start(sink: PCMSink, context: AudioSourceContext) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioSourceError.unreadableFile(url)
        }
        guard file.length > 0 else { throw AudioSourceError.unreadableFile(url) }

        let sampleRate = file.processingFormat.sampleRate
        let chunkFrames = AVAudioFrameCount(max(1, sampleRate * 0.1))
        metadata.detail = String(format: "%.1f kHz · %.1f s loop", sampleRate / 1000, Double(file.length) / sampleRate)

        task?.cancel()
        task = Task.detached(priority: .userInitiated) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { return }
            var deadline = ContinuousClock.now
            var emptyReads = 0
            while !Task.isCancelled {
                do {
                    try file.read(into: buffer, frameCount: chunkFrames)
                } catch {
                    return
                }
                if buffer.frameLength == 0 {
                    emptyReads += 1
                    if emptyReads > 2 { return }
                    file.framePosition = 0
                    continue
                }
                emptyReads = 0
                sink.write(buffer)
                // Pace delivery to real time so the ring sees a live-like stream.
                deadline += .seconds(Double(buffer.frameLength) / sampleRate)
                try? await Task.sleep(until: deadline, clock: .continuous)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
