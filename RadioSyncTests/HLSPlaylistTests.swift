import XCTest
@testable import RadioSync

final class HLSPlaylistTests: XCTestCase {

    private let base = URL(string: "https://cdn.example.com/radio/live/index.m3u8")!

    func testMasterPlaylistPrefersDefaultAudioRenditionThenCheapestAudioOnlyVariant() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-STREAM-INF:BANDWIDTH=2177116,CODECS="avc1.640020,mp4a.40.2",RESOLUTION=960x540,AUDIO="aud1"
        v5/prog_index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=185000,CODECS="mp4a.40.2"
        midfi.m3u8?id=x
        #EXT-X-STREAM-INF:BANDWIDTH=107000,CODECS="mp4a.40.2"
        lofi.m3u8?id=x
        """
        guard case .master(let master) = try HLSPlaylist.parse(text, url: base) else { return XCTFail("expected master") }
        XCTAssertEqual(master.variants.count, 3)
        XCTAssertEqual(master.preferredAudioURL?.absoluteString, "https://cdn.example.com/radio/live/lofi.m3u8?id=x")

        let withRendition = text + "\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud1\",NAME=\"English\",DEFAULT=YES,URI=\"a1/prog_index.m3u8\"\n"
        guard case .master(let master2) = try HLSPlaylist.parse(withRendition, url: base) else { return XCTFail("expected master") }
        XCTAssertEqual(master2.preferredAudioURL?.absoluteString, "https://cdn.example.com/radio/live/a1/prog_index.m3u8")
    }

    func testMasterWithOnlyVideoVariantsFallsBackToCheapest() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=320x180
        180.m3u8
        """
        guard case .master(let master) = try HLSPlaylist.parse(text, url: base) else { return XCTFail("expected master") }
        XCTAssertEqual(master.preferredAudioURL?.lastPathComponent, "180.m3u8")
    }

    func testLiveMediaPlaylistWithDiscontinuitiesAndTrailingWhitespace() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:118
        #EXT-X-DISCONTINUITY-SEQUENCE:4
        #EXT-X-PROGRAM-DATE-TIME:2026-09-04T02:48:13.149Z
        #EXTINF:10.010,\t
        https://cdn.example.com/a/one.aac
        #EXTINF:2.070,
        two.aac
        #EXT-X-DISCONTINUITY
        #EXTINF:10.010,
        /abs/three.aac
        """
        guard case .media(let media) = try HLSPlaylist.parse(text, url: base) else { return XCTFail("expected media") }
        XCTAssertEqual(media.targetDuration, 10)
        XCTAssertEqual(media.mediaSequence, 118)
        XCTAssertFalse(media.hasEndList)
        XCTAssertEqual(media.segments.count, 3)
        XCTAssertEqual(media.segments.map(\.sequence), [118, 119, 120])
        XCTAssertEqual(media.segments.map(\.discontinuitySequence), [4, 4, 5])
        XCTAssertEqual(media.segments[0].duration, 10.010, accuracy: 0.0001)
        XCTAssertEqual(media.segments[1].url.absoluteString, "https://cdn.example.com/radio/live/two.aac")
        XCTAssertEqual(media.segments[2].url.absoluteString, "https://cdn.example.com/abs/three.aac")
        XCTAssertNotNil(media.segments[0].programDateTime)
        XCTAssertNil(media.segments[1].programDateTime)
        XCTAssertEqual(media.totalDuration, 22.09, accuracy: 0.001)
    }

    func testVODWithByteRangesMapAndKey() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-VERSION:7
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="main.mp4",BYTERANGE="616@0"
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x0000000000000000000000000000ABCD
        #EXTINF:5.99467,
        #EXT-X-BYTERANGE:121090@616
        main.mp4
        #EXTINF:5.99467,
        #EXT-X-BYTERANGE:121201
        main.mp4
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:5.0,
        tail.mp4
        #EXT-X-ENDLIST
        """
        guard case .media(let media) = try HLSPlaylist.parse(text, url: base) else { return XCTFail("expected media") }
        XCTAssertTrue(media.hasEndList)
        XCTAssertEqual(media.segments.count, 3)
        XCTAssertEqual(media.segments[0].byteRange, .init(length: 121090, offset: 616))
        XCTAssertEqual(media.segments[1].byteRange, .init(length: 121201, offset: 121706), "offset continues from the previous range")
        XCTAssertEqual(media.segments[0].byteRange?.headerValue, "bytes=616-121705")
        XCTAssertEqual(media.segments[0].map?.url.lastPathComponent, "main.mp4")
        XCTAssertEqual(media.segments[0].map?.byteRange, .init(length: 616, offset: 0))
        XCTAssertEqual(media.segments[0].key?.method, .aes128)
        XCTAssertEqual(media.segments[0].key?.url?.lastPathComponent, "key.bin")
        XCTAssertEqual(media.segments[0].key?.iv?.count, 16)
        XCTAssertEqual(media.segments[0].key?.iv?.suffix(2), Data([0xAB, 0xCD]))
        XCTAssertNil(media.segments[2].key, "METHOD=NONE clears the key")
    }

    func testImplicitIVIsBigEndianSequenceNumber() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:258
        #EXT-X-KEY:METHOD=AES-128,URI="k"
        #EXTINF:4,
        s.ts
        """
        guard case .media(let media) = try HLSPlaylist.parse(text, url: base) else { return XCTFail("expected media") }
        let iv = HLSMediaPlaylist.iv(for: media.segments[0])
        XCTAssertEqual(iv.count, 16)
        XCTAssertEqual(Array(iv.suffix(2)), [0x01, 0x02])  // 258 = 0x0102
        XCTAssertTrue(iv.prefix(14).allSatisfy { $0 == 0 })
    }

    func testAttributeParsingHandlesQuotedCommas() {
        let attrs = HLSPlaylist.attributes(#"TYPE=AUDIO,NAME="English, US",DEFAULT=YES,URI="a/b.m3u8?x=1,2""#)
        XCTAssertEqual(attrs["TYPE"], "AUDIO")
        XCTAssertEqual(attrs["NAME"], "English, US")
        XCTAssertEqual(attrs["DEFAULT"], "YES")
        XCTAssertEqual(attrs["URI"], "a/b.m3u8?x=1,2")
    }

    func testRejectsNonPlaylists() {
        XCTAssertThrowsError(try HLSPlaylist.parse("<html>nope</html>", url: base))
        XCTAssertThrowsError(try HLSPlaylist.parse("#EXTM3U\n#EXT-X-TARGETDURATION:10\n", url: base))
    }

    func testPlainM3UAndPLSPointToStreams() {
        let m3u = "#EXTM3U\n#EXTINF:-1,Some Station\nhttp://stream.example.com:8000/live\n"
        XCTAssertEqual(StreamPipeline.firstStreamURL(inPlainPlaylist: m3u, base: base)?.absoluteString, "http://stream.example.com:8000/live")
        let pls = "[playlist]\nNumberOfEntries=1\nFile1=https://stream.example.com/live.mp3\nTitle1=X\n"
        XCTAssertEqual(StreamPipeline.firstStreamURL(inPlainPlaylist: pls, base: base)?.absoluteString, "https://stream.example.com/live.mp3")
    }

    func testLiveStartIndexLeavesRoomForCushionAndHistory() throws {
        // Twenty 10 s segments: cushion is 18 s (10 + 2*3 + 2), history 30 s → want 48 s → 5 segments back.
        var lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:10", "#EXT-X-MEDIA-SEQUENCE:0"]
        for index in 0..<20 { lines += ["#EXTINF:10.0,", "seg\(index).ts"] }
        guard case .media(let media) = try HLSPlaylist.parse(lines.joined(separator: "\n"), url: base) else { return XCTFail("expected media") }
        XCTAssertEqual(StreamPipeline.pollInterval(for: media), 3)
        XCTAssertEqual(StreamPipeline.cushionSeconds(for: media), 18)
        XCTAssertEqual(StreamPipeline.liveStartIndex(for: media), 16)

        // Short playlist: start at the beginning.
        var short = ["#EXTM3U", "#EXT-X-TARGETDURATION:10", "#EXT-X-MEDIA-SEQUENCE:0"]
        for index in 0..<3 { short += ["#EXTINF:10.0,", "seg\(index).ts"] }
        guard case .media(let media2) = try HLSPlaylist.parse(short.joined(separator: "\n"), url: base) else { return XCTFail("expected media") }
        XCTAssertEqual(StreamPipeline.liveStartIndex(for: media2), 0)
    }
}
