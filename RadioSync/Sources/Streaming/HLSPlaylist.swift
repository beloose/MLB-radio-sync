import Foundation

/// Just enough of HLS (RFC 8216) for live and on-demand audio: master playlists
/// with variants and audio renditions, and media playlists with segments, byte
/// ranges, init sections, keys, and discontinuities.
enum HLSPlaylist {
    case master(HLSMasterPlaylist)
    case media(HLSMediaPlaylist)

    enum ParseError: LocalizedError {
        case notAPlaylist
        case noSegments

        var errorDescription: String? {
            switch self {
            case .notAPlaylist: "The response is not an HLS playlist."
            case .noSegments: "The playlist has no media segments."
            }
        }
    }

    /// Parses `text` fetched from `url`; relative URIs resolve against `url`.
    static func parse(_ text: String, url: URL) throws -> HLSPlaylist {
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, first.hasPrefix("#EXTM3U") else { throw ParseError.notAPlaylist }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") || $0.hasPrefix("#EXT-X-MEDIA:") }) {
            return .master(HLSMasterPlaylist(lines: lines, url: url))
        }
        return .media(try HLSMediaPlaylist(lines: lines, url: url))
    }

    /// Resolves a playlist URI against its base, tolerating unescaped characters.
    static func resolve(_ reference: String, relativeTo base: URL) -> URL? {
        if let url = URL(string: reference, relativeTo: base) { return url.absoluteURL }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "/:?=&%#@+")
        guard let escaped = reference.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: escaped, relativeTo: base)?.absoluteURL
    }

    /// Splits `KEY=VALUE,KEY="quoted, value"` attribute lists.
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var quoted = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { result[k] = value }
            key = ""
            value = ""
            inKey = true
        }
        for character in text {
            if inKey {
                if character == "=" { inKey = false } else if character == "," { flush() } else { key.append(character) }
            } else if quoted {
                if character == "\"" { quoted = false } else { value.append(character) }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                flush()
            } else {
                value.append(character)
            }
        }
        flush()
        return result
    }

    static func byteRange(_ text: String) -> (length: Int, offset: Int?)? {
        let parts = text.split(separator: "@", maxSplits: 1).map(String.init)
        guard let first = parts.first, let length = Int(first) else { return nil }
        let offset = parts.count > 1 ? Int(parts[1]) : nil
        return (length, offset)
    }
}

struct HLSMasterPlaylist {
    struct Variant {
        var url: URL
        var bandwidth: Int
        var codecs: String?
        var resolution: String?
        var audioGroup: String?

        /// True if the variant carries no video.
        var isAudioOnly: Bool {
            if resolution != nil { return false }
            guard let codecs else { return true }
            return codecs.split(separator: ",").allSatisfy { codec in
                let c = codec.trimmingCharacters(in: .whitespaces).lowercased()
                return c.hasPrefix("mp4a") || c.hasPrefix("ec-3") || c.hasPrefix("ac-3") || c.hasPrefix("mp3") || c.hasPrefix("flac") || c.hasPrefix("opus")
            }
        }
    }

    struct Rendition {
        var url: URL
        var groupID: String
        var name: String?
        var language: String?
        var isDefault: Bool
    }

    var variants: [Variant] = []
    var audioRenditions: [Rendition] = []

    init(lines: [String], url: URL) {
        var pendingVariant: [String: String]?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingVariant = HLSPlaylist.attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = HLSPlaylist.attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard attrs["TYPE"] == "AUDIO", let uri = attrs["URI"], let resolved = HLSPlaylist.resolve(uri, relativeTo: url) else { continue }
                audioRenditions.append(Rendition(
                    url: resolved,
                    groupID: attrs["GROUP-ID"] ?? "",
                    name: attrs["NAME"],
                    language: attrs["LANGUAGE"],
                    isDefault: attrs["DEFAULT"] == "YES"
                ))
            } else if !line.hasPrefix("#"), let attrs = pendingVariant {
                pendingVariant = nil
                guard let resolved = HLSPlaylist.resolve(line, relativeTo: url) else { continue }
                variants.append(Variant(
                    url: resolved,
                    bandwidth: Int(attrs["BANDWIDTH"] ?? "") ?? Int(attrs["AVERAGE-BANDWIDTH"] ?? "") ?? 0,
                    codecs: attrs["CODECS"],
                    resolution: attrs["RESOLUTION"],
                    audioGroup: attrs["AUDIO"]
                ))
            }
        }
    }

    /// The media playlist to play for audio: the default audio rendition, else
    /// the cheapest audio-only variant, else the cheapest variant of all (its
    /// transport stream still carries an audio track we can demux).
    var preferredAudioURL: URL? {
        if let rendition = audioRenditions.first(where: \.isDefault) ?? audioRenditions.first {
            return rendition.url
        }
        let audioOnly = variants.filter(\.isAudioOnly)
        let pool = audioOnly.isEmpty ? variants : audioOnly
        return pool.min(by: { $0.bandwidth < $1.bandwidth })?.url
    }
}

struct HLSMediaPlaylist {
    struct ByteRange: Equatable {
        var length: Int
        var offset: Int
        var end: Int { offset + length }
        var headerValue: String { "bytes=\(offset)-\(end - 1)" }
    }

    struct Key: Equatable {
        enum Method: Equatable {
            case aes128
            case sampleAES
            case other(String)
        }
        var method: Method
        var url: URL?
        /// Explicit IV; when nil, the IV is the segment's media sequence number.
        var iv: Data?
    }

    struct Map: Equatable {
        var url: URL
        var byteRange: ByteRange?
    }

    struct Segment {
        var url: URL
        var duration: Double
        var sequence: Int
        var discontinuitySequence: Int
        var byteRange: ByteRange?
        var map: Map?
        var key: Key?
        var programDateTime: Date?
    }

    var targetDuration: Double
    var mediaSequence: Int
    var discontinuitySequence: Int
    var segments: [Segment]
    var hasEndList: Bool
    var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }

    init(lines: [String], url: URL) throws {
        var targetDuration = 0.0
        var mediaSequence = 0
        var discontinuitySequence = 0
        var segments: [Segment] = []
        var hasEndList = false

        var pendingDuration: Double?
        var pendingByteRange: (length: Int, offset: Int?)?
        var pendingDate: Date?
        var pendingDiscontinuity = false
        var currentKey: Key?
        var currentMap: Map?
        var lastRangeEnd = 0
        var sequence = 0
        var discontinuityCounter = 0
        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainDateParser = ISO8601DateFormatter()

        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                let body = line.dropFirst("#EXTINF:".count)
                let durationText = body.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
                pendingDuration = Double(durationText.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                sequence = mediaSequence
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
                discontinuitySequence = Int(line.dropFirst("#EXT-X-DISCONTINUITY-SEQUENCE:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                discontinuityCounter = discontinuitySequence
            } else if line == "#EXT-X-DISCONTINUITY" {
                pendingDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = HLSPlaylist.byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                let text = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count)).trimmingCharacters(in: .whitespaces)
                pendingDate = dateParser.date(from: text) ?? plainDateParser.date(from: text)
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = HLSPlaylist.attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = attrs["METHOD"] ?? "NONE"
                switch method {
                case "NONE":
                    currentKey = nil
                default:
                    let keyMethod: Key.Method = method == "AES-128" ? .aes128 : (method == "SAMPLE-AES" ? .sampleAES : .other(method))
                    let keyURL = attrs["URI"].flatMap { HLSPlaylist.resolve($0, relativeTo: url) }
                    currentKey = Key(method: keyMethod, url: keyURL, iv: attrs["IV"].flatMap(Self.parseIV))
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = HLSPlaylist.attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = attrs["URI"], let mapURL = HLSPlaylist.resolve(uri, relativeTo: url) {
                    var range: ByteRange?
                    if let text = attrs["BYTERANGE"], let parsed = HLSPlaylist.byteRange(text) {
                        range = ByteRange(length: parsed.length, offset: parsed.offset ?? 0)
                    }
                    currentMap = Map(url: mapURL, byteRange: range)
                }
            } else if line == "#EXT-X-ENDLIST" {
                hasEndList = true
            } else if !line.hasPrefix("#") {
                guard let duration = pendingDuration, let segmentURL = HLSPlaylist.resolve(line, relativeTo: url) else {
                    pendingDuration = nil
                    continue
                }
                var byteRange: ByteRange?
                if let pending = pendingByteRange {
                    byteRange = ByteRange(length: pending.length, offset: pending.offset ?? lastRangeEnd)
                    lastRangeEnd = byteRange!.end
                } else {
                    lastRangeEnd = 0
                }
                if pendingDiscontinuity { discontinuityCounter += 1 }
                segments.append(Segment(
                    url: segmentURL,
                    duration: duration,
                    sequence: sequence,
                    discontinuitySequence: discontinuityCounter,
                    byteRange: byteRange,
                    map: currentMap,
                    key: currentKey,
                    programDateTime: pendingDate
                ))
                sequence += 1
                pendingDuration = nil
                pendingByteRange = nil
                pendingDate = nil
                pendingDiscontinuity = false
            }
        }

        guard !segments.isEmpty else { throw HLSPlaylist.ParseError.noSegments }
        self.targetDuration = targetDuration > 0 ? targetDuration : (segments.map(\.duration).max() ?? 10)
        self.mediaSequence = mediaSequence
        self.discontinuitySequence = discontinuitySequence
        self.segments = segments
        self.hasEndList = hasEndList
    }

    private static func parseIV(_ text: String) -> Data? {
        var hex = text.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        // Left-pad to 16 bytes as the spec requires for short IVs.
        if data.count < 16 { data = Data(repeating: 0, count: 16 - data.count) + data }
        return data
    }

    /// The IV for `segment`: the explicit one, else its media sequence number as a
    /// 128-bit big-endian integer.
    static func iv(for segment: Segment) -> Data {
        if let iv = segment.key?.iv { return iv }
        var iv = Data(repeating: 0, count: 16)
        var value = UInt64(max(segment.sequence, 0)).bigEndian
        withUnsafeBytes(of: &value) { iv.replaceSubrange(8..<16, with: $0) }
        return iv
    }
}
