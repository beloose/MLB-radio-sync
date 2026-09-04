import AVFoundation

/// The kinds of stream the app can pull audio from. Step 4 adds `mlb` (MLB Audio).
enum AudioSourceKind: String, CaseIterable, Identifiable, Codable {
    case directURL
    case microphone
    case fileLoop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directURL: "Stream URL"
        case .microphone: "Mic passthrough"
        case .fileLoop: "Test pattern"
        }
    }

    var symbolName: String {
        switch self {
        case .directURL: "dot.radiowaves.left.and.right"
        case .microphone: "mic.fill"
        case .fileLoop: "waveform"
        }
    }
}

/// What a source knows about what it is playing, for the UI and the lock screen.
struct AudioSourceMetadata: Equatable, Sendable {
    var title: String
    var subtitle: String? = nil
    var detail: String? = nil
}

/// Everything a source may need from the engine while it runs.
struct AudioSourceContext {
    /// The live engine. Sources that capture audio tap `engine.inputNode`.
    let engine: AVAudioEngine
    /// Sample rate of the ring buffer. `PCMSink` converts for you; this is informational.
    let sampleRate: Double
    /// For failures after `start` returned (a stream that dies, a network that
    /// goes away for good). Safe to call from any thread; playback stops.
    let reportFailure: @Sendable (Error) -> Void
}

enum AudioSourceError: LocalizedError {
    case noAudioInput
    case unreadableFile(URL)
    case noStreamURL

    var errorDescription: String? {
        switch self {
        case .noAudioInput:
            "No audio input is available on this route."
        case .unreadableFile(let url):
            "Couldn't open \(url.lastPathComponent)."
        case .noStreamURL:
            "Enter a stream URL first."
        }
    }
}

/// A pluggable stream of PCM audio that feeds the ring buffer.
///
/// Sources own their acquisition (mic tap, file decode, HTTP fetch) and push PCM
/// into the sink they're given. They never touch the delay engine directly.
/// `start` is called before the engine starts and `stop` after it stops, always
/// on the main actor.
@MainActor
protocol AudioSource: AnyObject {
    var kind: AudioSourceKind { get }
    /// True if the source captures through the audio input. The engine then
    /// configures the session for play-and-record before calling `start`.
    var needsMicrophone: Bool { get }
    /// True if the source must be stopped and started again whenever the engine
    /// graph is rebuilt (route change, interruption), because it is attached to
    /// the engine. Network and file sources keep running across a rebuild.
    var restartsWithEngine: Bool { get }
    var metadata: AudioSourceMetadata { get }

    func start(sink: PCMSink, context: AudioSourceContext) throws
    func stop()
}

extension AudioSource {
    var restartsWithEngine: Bool { true }
}
