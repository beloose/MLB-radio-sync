import AVFoundation

/// The kinds of stream the app can pull audio from. Later build steps add
/// `directURL` (any HLS/Icecast URL) and `mlb` (MLB Audio).
enum AudioSourceKind: String, CaseIterable, Identifiable, Codable {
    case microphone
    case fileLoop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Mic passthrough"
        case .fileLoop: "Test pattern"
        }
    }

    var symbolName: String {
        switch self {
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
}

enum AudioSourceError: LocalizedError {
    case noAudioInput
    case unreadableFile(URL)

    var errorDescription: String? {
        switch self {
        case .noAudioInput:
            "No audio input is available on this route."
        case .unreadableFile(let url):
            "Couldn't open \(url.lastPathComponent)."
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
    var metadata: AudioSourceMetadata { get }

    func start(sink: PCMSink, context: AudioSourceContext) throws
    func stop()
}
