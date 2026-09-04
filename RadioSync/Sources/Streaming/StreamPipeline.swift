import AVFoundation
import AudioToolbox
import CommonCrypto
import Foundation

/// What the pipeline knows about the stream, for the UI.
struct StreamStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case connecting
        case live
        case reconnecting(String)
        case ended
    }

    var host: String = ""
    /// "HLS", "Icecast", "HTTP".
    var transport: String = ""
    /// e.g. "AAC 44.1 kHz stereo", once known.
    var codec: String?
    var phase: Phase = .connecting
    /// Audio downloaded but not yet due in the ring.
    var cushionSeconds: Double = 0
}

enum StreamFailure: LocalizedError {
    case httpStatus(Int, URL)
    case notAnAudioStream(String)
    case unsupported(String)
    case network(String)
    case gaveUp(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let url): "\(url.host ?? "The server") answered HTTP \(code)."
        case .notAnAudioStream(let why): "That URL isn't an audio stream (\(why))."
        case .unsupported(let what): "Unsupported stream: \(what)."
        case .network(let why): why
        case .gaveUp(let why): "Gave up: \(why)"
        }
    }
}

/// Fetches one URL (HLS playlist or progressive Icecast/HTTP stream), decodes
/// it, and paces the PCM into a `PCMSink` in real time. Runs entirely on
/// background tasks; callbacks may arrive on any thread.
final class StreamPipeline: @unchecked Sendable {

    typealias StatusHandler = @Sendable (StreamStatus) -> Void
    typealias FailureHandler = @Sendable (Error) -> Void

    /// History to burst into the ring at start (beyond the cushion) so delays
    /// up to this long fill instantly instead of waiting for real time to pass.
    static let initialHistorySeconds: Double = 30
    /// Cap on the one-shot burst, to bound memory and startup time.
    static let maxBurstSeconds: Double = 45
    /// Stop fetching ahead when this much is queued (on-demand playlists).
    static let maxQueuedSeconds: Double = 60
    static let userAgent = "RadioSync/0.1 (iPhone; +https://github.com/beloose/MLB-radio-sync)"

    private let url: URL
    private let sink: PCMSink
    private let onStatus: StatusHandler
    private let onFailure: FailureHandler
    private let queue = PCMQueue()
    private let pacer: PacedSinkWriter
    private let session: URLSession
    private let lock = NSLock()
    private var status = StreamStatus()
    private var isStopped = false
    private var networkTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?

    init(url: URL, sink: PCMSink, onStatus: @escaping StatusHandler, onFailure: @escaping FailureHandler) {
        self.url = url
        self.sink = sink
        self.onStatus = onStatus
        self.onFailure = onFailure
        pacer = PacedSinkWriter(queue: queue, sink: sink)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.networkServiceType = .avStreaming
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept": "*/*"]
        session = URLSession(configuration: configuration)

        status.host = (url.host ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
    }

    var stats: PacedSinkWriter.Stats { pacer.stats }

    func start() {
        pacer.start()
        networkTask = Task.detached(priority: .userInitiated) { [self] in
            await run()
        }
        statusTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.update { $0.cushionSeconds = (self.pacer.stats.cushionSeconds * 10).rounded() / 10 }
            }
        }
    }

    func stop() {
        lock.withLock { isStopped = true }
        networkTask?.cancel()
        statusTask?.cancel()
        networkTask = nil
        statusTask = nil
        pacer.stop()
        queue.removeAll()
        session.invalidateAndCancel()
    }

    // MARK: Status

    private func update(_ change: (inout StreamStatus) -> Void) {
        var snapshot: StreamStatus?
        lock.withLock {
            guard !isStopped else { return }
            let before = status
            change(&status)
            if status != before { snapshot = status }
        }
        if let snapshot { onStatus(snapshot) }
    }

    private func fail(_ error: Error) {
        let stopped = lock.withLock { isStopped }
        guard !stopped else { return }
        onFailure(error)
    }

    // MARK: Entry

    private func run() async {
        do {
            switch try await open(url, depth: 0) {
            case .hls(let playlistURL, let playlist):
                try await runHLS(playlistURL: playlistURL, first: playlist)
            case .progressive(let stream):
                try await runProgressive(stream)
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            fail(error)
        }
    }

    private struct ProgressiveStream {
        var url: URL
        var mimeType: String
        var isIcecast: Bool
        var iterator: URLSession.AsyncBytes.AsyncIterator
        var prefix: Data
    }

    private enum Opened {
        case hls(URL, HLSMediaPlaylist)
        case progressive(ProgressiveStream)
    }

    /// Fetches `url` and decides what it is, following playlists-of-playlists.
    private func open(_ url: URL, depth: Int) async throws -> Opened {
        guard depth < 4 else { throw StreamFailure.notAnAudioStream("too many playlist redirections") }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse else { throw StreamFailure.notAnAudioStream("not an HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw StreamFailure.httpStatus(http.statusCode, url) }
        let finalURL = http.url ?? url
        let mime = (http.mimeType ?? "").lowercased()
        let ext = finalURL.pathExtension.lowercased()
        let headerNames = Set(http.allHeaderFields.keys.compactMap { ($0 as? String)?.lowercased() })
        let isIcecast = headerNames.contains { $0.hasPrefix("icy-") } || (http.value(forHTTPHeaderField: "Server") ?? "").lowercased().contains("icecast")

        var iterator = bytes.makeAsyncIterator()
        var prefix = Data()
        while prefix.count < 16, let byte = try await iterator.next() { prefix.append(byte) }

        let looksLikeM3U = prefix.starts(with: Array("#EXTM3U".utf8))
        let looksLikePLS = prefix.starts(with: Array("[playlist]".utf8))
        let playlistByType = mime.contains("mpegurl") || mime.contains("scpls") || ["m3u8", "m3u", "pls"].contains(ext)

        if looksLikeM3U || looksLikePLS || playlistByType {
            var body = prefix
            while let byte = try await iterator.next() {
                body.append(byte)
                if body.count > 4_000_000 { throw StreamFailure.notAnAudioStream("playlist too large") }
            }
            let text = String(decoding: body, as: UTF8.self)
            if text.hasPrefix("#EXTM3U") {
                switch try HLSPlaylist.parse(text, url: finalURL) {
                case .master(let master):
                    guard let next = master.preferredAudioURL else { throw StreamFailure.notAnAudioStream("master playlist has no audio") }
                    return try await open(next, depth: depth + 1)
                case .media(let media):
                    return .hls(finalURL, media)
                }
            }
            if let next = Self.firstStreamURL(inPlainPlaylist: text, base: finalURL) {
                return try await open(next, depth: depth + 1)
            }
            throw StreamFailure.notAnAudioStream("playlist has no stream URL")
        }

        if mime.hasPrefix("text/html") || prefix.starts(with: Array("<".utf8)) {
            throw StreamFailure.notAnAudioStream("it's a web page")
        }
        if mime.contains("ogg") || ext == "ogg" || ext == "opus" || prefix.starts(with: Array("OggS".utf8)) {
            throw StreamFailure.unsupported("Ogg container")
        }
        return .progressive(ProgressiveStream(url: finalURL, mimeType: mime, isIcecast: isIcecast, iterator: iterator, prefix: prefix))
    }

    /// First http(s) URL in a plain .m3u or .pls file.
    static func firstStreamURL(inPlainPlaylist text: String, base: URL) -> URL? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") { continue }
            if let equals = line.firstIndex(of: "="), line.lowercased().hasPrefix("file") {
                line = String(line[line.index(after: equals)...])
            }
            if line.lowercased().hasPrefix("http"), let url = HLSPlaylist.resolve(line, relativeTo: base) { return url }
        }
        return nil
    }

    // MARK: HLS

    private func runHLS(playlistURL: URL, first: HLSMediaPlaylist) async throws {
        update {
            $0.transport = "HLS"
            $0.phase = .connecting
        }
        var playlist = first
        var nextSequence: Int?
        var decoder: SegmentDecoder?
        var decoderDiscontinuity: Int?
        var decoderMap: HLSMediaPlaylist.Map?
        var lastOutputFormat: AVAudioFormat?
        var keyCache: [URL: Data] = [:]
        var segmentFailures = 0
        var playlistFailures = 0
        var begun = false
        var lastPlaylistFetch = ContinuousClock.now

        while true {
            try Task.checkCancellation()

            // Which segments are new to us?
            var toPlay: [HLSMediaPlaylist.Segment] = []
            var isFreshStart = false
            if let next = nextSequence {
                if let index = playlist.segments.firstIndex(where: { $0.sequence >= next }) {
                    if playlist.segments[index].sequence > next {
                        // The segments we needed have already left the playlist.
                        isFreshStart = true
                    } else {
                        toPlay = Array(playlist.segments[index...])
                    }
                } else if let last = playlist.segments.last, last.sequence < next - 1 {
                    // Sequence numbers went backwards: the origin restarted.
                    isFreshStart = true
                }
            } else {
                isFreshStart = true
            }
            if isFreshStart {
                let start = playlist.hasEndList ? 0 : Self.liveStartIndex(for: playlist)
                toPlay = Array(playlist.segments[start...])
                if begun {
                    // Content was lost; keep the ring on real time and re-form the cushion.
                    pacer.resync()
                    update { $0.phase = .reconnecting("skipped ahead") }
                }
                decoder = nil
            }
            var initialRemaining = (!begun && isFreshStart) ? toPlay.count : 0
            if playlist.hasEndList { initialRemaining = min(initialRemaining, 1) }

            for segment in toPlay {
                try Task.checkCancellation()
                while begun, queue.queuedSeconds > Self.maxQueuedSeconds {
                    try await Task.sleep(for: .milliseconds(500))
                }

                let needsNewDecoder = decoder == nil
                    || decoderDiscontinuity != segment.discontinuitySequence
                    || decoderMap != segment.map
                do {
                    let data = try await fetchSegment(segment, keyCache: &keyCache)
                    if needsNewDecoder {
                        let fresh = SegmentDecoder()
                        if let map = segment.map {
                            let initData = try await fetch(map.url, byteRange: map.byteRange)
                            fresh.setInitSegment(initData)
                        }
                        decoder = fresh
                        decoderDiscontinuity = segment.discontinuitySequence
                        decoderMap = segment.map
                    }
                    guard let decoder else { continue }
                    let buffers = try decoder.decode(segment: data)
                    for buffer in buffers { queue.enqueue(buffer) }
                    if let format = decoder.outputFormat { lastOutputFormat = format }
                    segmentFailures = 0
                    let codec = decoder.formatDescription
                    update {
                        $0.codec = codec
                        if begun { $0.phase = .live }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch let error as AudioStreamDecoder.DecodeError {
                    throw error
                } catch let error as MPEGTSDemuxer.DemuxError {
                    throw error
                } catch let error as StreamFailure {
                    if case .httpStatus(let code, _) = error, code == 403 || code == 401 { throw error }
                    segmentFailures += 1
                    if segmentFailures >= 5 { throw StreamFailure.gaveUp(error.localizedDescription) }
                    // Keep the timeline: the missing segment becomes silence.
                    if begun, let format = lastOutputFormat {
                        queue.enqueueSilence(seconds: segment.duration, format: format)
                    }
                    update { $0.phase = .reconnecting(error.localizedDescription) }
                } catch {
                    segmentFailures += 1
                    if segmentFailures >= 5 { throw StreamFailure.gaveUp(error.localizedDescription) }
                    if begun, let format = lastOutputFormat {
                        queue.enqueueSilence(seconds: segment.duration, format: format)
                    }
                    update { $0.phase = .reconnecting(error.localizedDescription) }
                }
                nextSequence = segment.sequence + 1

                if initialRemaining > 0 {
                    initialRemaining -= 1
                    if initialRemaining == 0 {
                        let burst = playlist.hasEndList ? 0 : min(max(0, queue.queuedSeconds - Self.cushionSeconds(for: playlist)), Self.maxBurstSeconds)
                        pacer.begin(burstSeconds: burst)
                        begun = true
                        update { $0.phase = .live }
                    }
                }
            }

            if playlist.hasEndList {
                update { $0.phase = .ended }
                while true { try await Task.sleep(for: .seconds(60)) }
            }

            // Reload the playlist, measured from the last fetch.
            let dueAt = lastPlaylistFetch + .seconds(Self.pollInterval(for: playlist))
            if dueAt > .now { try await Task.sleep(until: dueAt, clock: .continuous) }
            do {
                lastPlaylistFetch = .now
                let (data, _) = try await fetchData(playlistURL, byteRange: nil)
                switch try HLSPlaylist.parse(String(decoding: data, as: UTF8.self), url: playlistURL) {
                case .media(let fresh): playlist = fresh
                case .master: throw StreamFailure.notAnAudioStream("media playlist turned into a master playlist")
                }
                playlistFailures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                playlistFailures += 1
                if playlistFailures >= 12 { throw StreamFailure.gaveUp(error.localizedDescription) }
                update { $0.phase = .reconnecting(error.localizedDescription) }
                try await Task.sleep(for: .seconds(min(Double(playlistFailures) * 2, 10)))
            }
        }
    }

    /// How often to reload a live playlist. Faster than the HLS guideline of
    /// one target duration; the cost is a few small requests per segment and
    /// the benefit is a smaller cushion.
    static func pollInterval(for playlist: HLSMediaPlaylist) -> Double {
        min(max(playlist.targetDuration / 2, 1), 3)
    }

    /// Audio to hold back from the ring on a live playlist. Segments arrive in
    /// bursts every segment duration `d`, observed with up to one poll interval
    /// `p` of jitter each side, so the cushion right after an arrival must cover
    /// `d + 2p` plus download time for the ring never to run dry.
    static func cushionSeconds(for playlist: HLSMediaPlaylist) -> Double {
        let segmentDuration = max(playlist.targetDuration, playlist.segments.suffix(3).map(\.duration).max() ?? 0)
        return max(6, segmentDuration + 2 * pollInterval(for: playlist) + 2)
    }

    /// Where to join a live playlist: far enough back to hold the cushion plus
    /// `initialHistorySeconds` of instantly available history, if the playlist
    /// lists that much.
    static func liveStartIndex(for playlist: HLSMediaPlaylist) -> Int {
        let wanted = cushionSeconds(for: playlist) + initialHistorySeconds
        let segments = playlist.segments
        var index = segments.count - 1
        var accumulated = segments[index].duration
        while index > 0, accumulated + segments[index - 1].duration <= wanted {
            index -= 1
            accumulated += segments[index].duration
        }
        return index
    }

    private func fetchSegment(_ segment: HLSMediaPlaylist.Segment, keyCache: inout [URL: Data]) async throws -> Data {
        var data = try await fetch(segment.url, byteRange: segment.byteRange)
        if let key = segment.key {
            switch key.method {
            case .aes128:
                guard let keyURL = key.url else { throw StreamFailure.unsupported("encrypted segment without a key URL") }
                let keyData: Data
                if let cached = keyCache[keyURL] {
                    keyData = cached
                } else {
                    keyData = try await fetch(keyURL, byteRange: nil)
                    keyCache[keyURL] = keyData
                }
                guard keyData.count == kCCKeySizeAES128 else { throw StreamFailure.unsupported("AES key of \(keyData.count) bytes") }
                data = try Self.decryptAES128CBC(data, key: keyData, iv: HLSMediaPlaylist.iv(for: segment))
            case .sampleAES:
                throw StreamFailure.unsupported("SAMPLE-AES encryption")
            case .other(let method):
                throw StreamFailure.unsupported("\(method) encryption")
            }
        }
        return data
    }

    private func fetch(_ url: URL, byteRange: HLSMediaPlaylist.ByteRange?) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await fetchData(url, byteRange: byteRange).0
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as StreamFailure {
                if case .httpStatus(let code, _) = error, (400..<500).contains(code), code != 408, code != 429 { throw error }
                lastError = error
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
        }
        throw lastError ?? StreamFailure.network("download failed")
    }

    private func fetchData(_ url: URL, byteRange: HLSMediaPlaylist.ByteRange?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if let byteRange { request.setValue(byteRange.headerValue, forHTTPHeaderField: "Range") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StreamFailure.network("no HTTP response from \(url.host ?? "server")") }
        guard (200..<300).contains(http.statusCode) else { throw StreamFailure.httpStatus(http.statusCode, url) }
        return (data, http)
    }

    static func decryptAES128CBC(_ data: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            key.baseAddress, kCCKeySizeAES128, iv.baseAddress,
                            input.baseAddress, data.count, out.baseAddress, out.count, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw StreamFailure.unsupported("AES decryption failed (\(status))") }
        output.count = moved
        return output
    }

    // MARK: Progressive (Icecast / Shoutcast / plain HTTP)

    private func runProgressive(_ opened: ProgressiveStream) async throws {
        var stream = opened
        update {
            $0.transport = stream.isIcecast ? "Icecast" : "HTTP"
            $0.phase = .connecting
        }
        var begun = false
        var attempts = 0

        while true {
            try Task.checkCancellation()
            let decoder = try AudioStreamDecoder(fileTypeHint: Self.fileTypeHint(mimeType: stream.mimeType, url: stream.url))
            var chunk = stream.prefix
            var receivedSinceConnect = 0
            var connectionError: Error?
            do {
                while true {
                    guard let byte = try await stream.iterator.next() else { break }
                    chunk.append(byte)
                    if chunk.count >= 2048 {
                        let buffers = try decoder.decode(chunk)
                        receivedSinceConnect += chunk.count
                        chunk.removeAll(keepingCapacity: true)
                        for buffer in buffers { queue.enqueue(buffer) }
                        if !buffers.isEmpty {
                            if !begun {
                                pacer.begin(burstSeconds: 0)
                                begun = true
                            }
                            let codec = decoder.formatDescription
                            update {
                                $0.codec = codec
                                $0.phase = .live
                            }
                        }
                        if receivedSinceConnect > 512_000 { attempts = 0 }
                    }
                }
                connectionError = StreamFailure.network("The server closed the connection.")
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as AudioStreamDecoder.DecodeError {
                if receivedSinceConnect == 0 { throw error }
                connectionError = error  // mid-stream garbage: reconnect
            } catch {
                connectionError = error
            }

            // Reconnect with backoff.
            attempts += 1
            let reason = connectionError?.localizedDescription ?? "connection lost"
            if attempts > 8 { throw StreamFailure.gaveUp(reason) }
            update { $0.phase = .reconnecting(reason) }
            try await Task.sleep(for: .seconds(min(pow(2, Double(attempts - 1)), 10)))
            do {
                guard case .progressive(let reopened) = try await open(url, depth: 0) else {
                    throw StreamFailure.notAnAudioStream("the stream changed type")
                }
                stream = reopened
                if begun { pacer.resync() }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
    }

    static func fileTypeHint(mimeType: String, url: URL) -> AudioFileTypeID {
        let ext = url.pathExtension.lowercased()
        if mimeType.contains("mpeg") || mimeType.contains("mp3") || ext == "mp3" { return kAudioFileMP3Type }
        if mimeType.contains("aac") || ext == "aac" { return kAudioFileAAC_ADTSType }
        if mimeType.contains("mp4") || mimeType.contains("m4a") || ext == "mp4" || ext == "m4a" { return kAudioFileMPEG4Type }
        if mimeType.contains("flac") || ext == "flac" { return kAudioFileFLACType }
        return 0
    }
}

/// Handles one run of HLS segments between discontinuities: detects the
/// container, demuxes transport streams, strips ID3 headers from packed audio,
/// feeds fMP4 init sections, and keeps one continuous decoder.
final class SegmentDecoder {

    enum Container {
        case transportStream
        case packedAudio
        case fragmentedMP4
    }

    private(set) var container: Container?
    private var demuxer = MPEGTSDemuxer()
    private var decoder: AudioStreamDecoder?
    private var initSegment: Data?

    var formatDescription: String? { decoder?.formatDescription }
    var outputFormat: AVAudioFormat? { decoder?.outputFormat }

    func setInitSegment(_ data: Data) {
        initSegment = data
    }

    func decode(segment data: Data) throws -> [AVAudioPCMBuffer] {
        guard !data.isEmpty else { return [] }
        if container == nil { container = Self.detectContainer(data) ?? (initSegment != nil ? .fragmentedMP4 : .packedAudio) }

        switch container! {
        case .transportStream:
            let elementary = try demuxer.demux(data)
            if decoder == nil, let codec = demuxer.codec {
                switch codec {
                case .aacADTS: decoder = try AudioStreamDecoder(fileTypeHint: kAudioFileAAC_ADTSType)
                case .mpegAudio: decoder = try AudioStreamDecoder(fileTypeHint: kAudioFileMP3Type)
                case .unsupported: throw MPEGTSDemuxer.DemuxError.unsupportedAudio(codec)
                }
            }
            guard let decoder, !elementary.isEmpty else { return [] }
            return try decoder.decode(elementary)

        case .packedAudio:
            let payload = Self.strippingID3(data)
            if decoder == nil { decoder = try AudioStreamDecoder(fileTypeHint: Self.sniffElementaryType(payload)) }
            return try decoder!.decode(payload)

        case .fragmentedMP4:
            if decoder == nil {
                let fresh = try AudioStreamDecoder(fileTypeHint: kAudioFileMPEG4Type)
                if let initSegment { _ = try fresh.decode(initSegment) }
                decoder = fresh
            }
            return try decoder!.decode(data)
        }
    }

    static func detectContainer(_ data: Data) -> Container? {
        if MPEGTSDemuxer.looksLikeTransportStream(data) { return .transportStream }
        if data.count >= 12 {
            let box = String(decoding: data[data.startIndex + 4..<data.startIndex + 8], as: UTF8.self)
            if ["ftyp", "styp", "moof", "moov", "sidx", "free", "skip"].contains(box) { return .fragmentedMP4 }
        }
        if data.starts(with: Array("ID3".utf8)) { return .packedAudio }
        if data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] & 0xE0 == 0xE0 { return .packedAudio }
        return nil
    }

    /// Removes any ID3v2 tags at the start (HLS packed audio carries a timestamp tag per segment).
    static func strippingID3(_ data: Data) -> Data {
        var offset = data.startIndex
        while data.endIndex - offset >= 10, data[offset] == 0x49, data[offset + 1] == 0x44, data[offset + 2] == 0x33 {
            let flags = data[offset + 5]
            let size = (Int(data[offset + 6] & 0x7F) << 21) | (Int(data[offset + 7] & 0x7F) << 14) | (Int(data[offset + 8] & 0x7F) << 7) | Int(data[offset + 9] & 0x7F)
            let total = 10 + size + (flags & 0x10 != 0 ? 10 : 0)
            guard data.endIndex - offset >= total else { break }
            offset += total
        }
        return offset == data.startIndex ? data : data[offset...]
    }

    static func sniffElementaryType(_ data: Data) -> AudioFileTypeID {
        guard data.count >= 2 else { return 0 }
        let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
        if b0 == 0xFF && b1 & 0xF6 == 0xF0 { return kAudioFileAAC_ADTSType }
        if b0 == 0xFF && b1 & 0xE0 == 0xE0 { return kAudioFileMP3Type }
        return 0
    }
}
