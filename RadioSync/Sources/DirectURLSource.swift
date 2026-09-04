import AVFoundation
import Foundation

/// Plays any HLS playlist or Icecast/Shoutcast stream URL through the delay
/// buffer. The heavy lifting is in `StreamPipeline`; this object adapts it to
/// the `AudioSource` protocol and turns its status into metadata for the UI.
@MainActor
final class DirectURLSource: AudioSource {

    let kind: AudioSourceKind = .directURL
    let needsMicrophone = false
    let restartsWithEngine = false
    private(set) var metadata: AudioSourceMetadata

    var url: URL? {
        didSet {
            guard pipeline == nil else { return }
            metadata = Self.idleMetadata(for: url)
        }
    }

    private var pipeline: StreamPipeline?
    private var generation = 0

    init(url: URL? = nil) {
        self.url = url
        metadata = Self.idleMetadata(for: url)
    }

    func start(sink: PCMSink, context: AudioSourceContext) throws {
        guard let url else { throw AudioSourceError.noStreamURL }
        stop()
        generation += 1
        let generation = generation
        let pipeline = StreamPipeline(
            url: url,
            sink: sink,
            onStatus: { [weak self] status in
                Task { @MainActor in
                    guard let self, self.generation == generation, self.pipeline != nil else { return }
                    self.metadata = Self.metadata(for: status, url: url)
                }
            },
            onFailure: context.reportFailure
        )
        self.pipeline = pipeline
        metadata = AudioSourceMetadata(title: Self.title(for: url), subtitle: "Connecting…")
        pipeline.start()
    }

    func stop() {
        pipeline?.stop()
        pipeline = nil
        generation += 1
        metadata = Self.idleMetadata(for: url)
    }

    // MARK: Metadata

    static func title(for url: URL) -> String {
        let host = (url.host ?? url.absoluteString).lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func idleMetadata(for url: URL?) -> AudioSourceMetadata {
        guard let url else {
            return AudioSourceMetadata(title: "Stream URL", subtitle: "No URL set")
        }
        return AudioSourceMetadata(title: title(for: url), subtitle: url.lastPathComponent.isEmpty ? "Stream" : url.lastPathComponent)
    }

    private static func metadata(for status: StreamStatus, url: URL) -> AudioSourceMetadata {
        var subtitle = status.transport
        if let codec = status.codec { subtitle += " · \(codec)" }
        let detail: String
        switch status.phase {
        case .connecting:
            detail = "Connecting…"
        case .live:
            detail = String(format: "Live · %.1f s buffered", status.cushionSeconds)
        case .reconnecting(let reason):
            detail = "Reconnecting… \(reason)"
        case .ended:
            detail = "Stream ended"
        }
        return AudioSourceMetadata(title: title(for: url), subtitle: subtitle, detail: detail)
    }
}
