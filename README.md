# RadioSync

A personal iPhone app that plays a radio broadcast through an adjustable delay
buffer so it lines up with the TV. Native Swift + SwiftUI, everything on-device.
The full project spec is in [`docs/radio-tv-sync-spec.md`](docs/radio-tv-sync-spec.md).

## Status

Build order from the spec:

| Step | What | Status |
|------|------|--------|
| 1 | Xcode project scaffold, background audio, README | done |
| 2 | Ring buffer + delay engine + UI, driven by mic passthrough | done |
| 3 | Direct URL source (HLS / Icecast fetch → decode → ring) | done |
| 4 | MLB module (auth, game discovery, feed picker) | next |
| 5 | Auto-sync via microphone (Phase 2) | |
| 6 | Polish, drift correction (Phase 3) | |

## Requirements

- A Mac with **Xcode 26** or newer (the project targets iOS 26.0; change
  `IPHONEOS_DEPLOYMENT_TARGET` in the project if you need older).
- An iPhone running iOS 26 or newer, and a free Apple ID for signing.

## Build and install on your iPhone

1. Open `RadioSync.xcodeproj` in Xcode.
2. Select the **RadioSync** target → **Signing & Capabilities**:
   - Tick **Automatically manage signing**.
   - Pick your **Team** (a free "Personal Team" works).
   - If Xcode complains the bundle ID is taken, change
     `com.beloose.RadioSync` to anything unique (also update
     `PRODUCT_BUNDLE_IDENTIFIER` on the test target).
3. Plug in the iPhone (or pair it over Wi-Fi) and pick it as the run destination.
4. On the phone, enable **Settings › Privacy & Security › Developer Mode** if
   prompted, then reboot.
5. Press **Run** (⌘R). First run on a new team: on the phone go to
   **Settings › General › VPN & Device Management** and trust your developer
   certificate, then launch the app again.

Notes:
- With a free Personal Team the install expires after 7 days; just run from
  Xcode again.
- Run the unit tests with ⌘U (they run in the simulator; no device needed).
- The Simulator can also run the app: its microphone comes from the Mac.

## Using it (step 3 state)

Three sources exist right now, picked with the round button top-right:

- **Stream URL** — any HLS playlist (`.m3u8`, master or media) or a direct
  Icecast / Shoutcast stream (MP3, AAC, HE-AAC). The first time you pick it a
  sheet asks for the URL; there are a few examples in it, including WEEI's
  own web stream. The app downloads and decodes the audio itself (no
  `AVPlayer`), so the delay controls work on it exactly like on the mic.
  The header shows transport and codec plus how much audio is buffered
  ahead. Plain-`http` URLs are allowed (see `NSAppTransportSecurity` in
  `Info.plist`). Change the URL later from the same menu.
- **Mic passthrough** — the phone's mic goes into the delay buffer and out the
  speaker / Bluetooth / AirPlay. Point it at a real radio and it becomes a
  delay line for it. It is also the quickest way to test the engine: any
  sound in the room works. Wear headphones or use a Bluetooth speaker away
  from the phone; the speaker feeding back into the mic gets loud fast.
- **Test pattern** — loops a bundled 10 s clip. Second 0 is a long tone, and
  second *k* has *k* blips, so you can hear the delay change: raise the delay
  by 3 s during "five blips" and it jumps back to "two blips".

Controls:

- Big readout shows the current delay to 0.1 s. Slider sets it coarsely
  (applied when you let go); the four buttons nudge by ±1 s / ±0.1 s and
  apply instantly with a 50 ms crossfade so they don't click.
- **Play** starts the source. If the delay is, say, 30 s, the app shows
  "Buffering to +30.0 s · 40%" until 30 s of audio have been captured, then
  plays. Lowering the delay while buffering starts playback sooner.
- **Pause** freezes the output while the source keeps recording, so the
  delay grows by however long you were paused (this is the "pause the radio
  until it matches the TV" trick, made exact). Resume plays on from where it
  stopped at the new, larger delay. Delay is capped at 90 s.
- **Stop** tears everything down.
- Lock screen / Control Center show the source and delay and offer
  play/pause/stop. Playback continues with the screen locked (Audio
  background mode).
- Delay, volume, and source are remembered across launches.

## How the delay engine works

```
source (mic tap / file loop / stream URL)  →  PCMSink  →  PCMRingBuffer (mono float32, 48 kHz, ~175 s)
                                                                  ↑ write position
                                              DelayReader reads at (write position − delay)
                                                                  ↓
                                AVAudioSourceNode → main mixer → output route
```

- `PCMRingBuffer` (`RadioSync/Audio/`) is a lock-free single-producer /
  single-consumer ring with absolute frame positions, so "the frame written
  N frames ago" is just arithmetic.
- `DelayReader` runs on the audio render thread (no locks, no allocation).
  It fills to the requested delay, then plays. Delay changes move the read
  position *relative* to where it is, so a +0.1 s nudge is exactly +0.1 s no
  matter how the source chunks its writes. Underruns and pauses freeze the
  read position and are added to the reported delay, so the number on screen
  is always the true reader/writer distance.
- `DelayEngine` owns the `AVAudioEngine` graph and rebuilds it on every
  start so a mic session never poisons a later playback-only session.
- `AudioSource` is the protocol every stream conforms to. `MicPassthroughSource`,
  `FileLoopSource`, and `DirectURLSource` are in `RadioSync/Sources/`; step 4
  adds the MLB source, without touching the engine.
- `PlayerModel` (`RadioSync/Model/`) is the single `@Observable` model the
  SwiftUI views bind to; it also handles interruptions, route changes, and
  the lock-screen commands.

## How the stream source works

`RadioSync/Sources/Streaming/` is self-contained and knows nothing about the
UI or the engine beyond `PCMSink`:

```
URL ─▶ StreamPipeline.open()  classify: HLS master → rendition → media playlist,
   │                          plain .m3u/.pls → follow, anything else → progressive
   ├─ HLS loop:  playlist poll ─▶ segment fetch (byte ranges, AES-128) ─▶ SegmentDecoder
   │                              (MPEG-TS demux | ID3-stripped ADTS/MP3 | fMP4 + init)
   └─ progressive loop: URLSession bytes ─▶ AudioStreamDecoder
                                                  │  (AudioFileStream + AVAudioConverter,
                                                  ▼   one continuous decoder per discontinuity)
                                     PCMQueue ─▶ PacedSinkWriter ─▶ PCMSink ─▶ ring
```

- **Pacing.** Segments arrive in bursts, but the ring must see a write
  position that advances like a live capture or the delay reader's
  accounting (and the number on screen) drifts. `PacedSinkWriter` therefore
  releases decoded audio at exactly real time and keeps the rest queued as a
  *cushion* that absorbs late segments silently. The cushion is sized from
  the playlist: one segment duration plus two poll intervals plus 2 s
  (18 s for 10 s segments, 10 s for 4 s segments). That cushion is the only
  latency the stream adds on top of the origin's own.
- **Start-up.** On a live playlist the app joins far enough back to hold the
  cushion *and* ~30 s of history, and writes that history into the ring in
  one shot, so a saved delay of, say, 25 s starts playing immediately
  instead of buffering for 25 s. Zero delay means "the newest audio we have".
- **Failures.** A segment that won't download becomes silence of its length
  (the timeline stays honest); if the playlist has moved past what we needed,
  or an Icecast connection drops, the writer fills the gap with silence and
  re-forms the cushion from the fresh data. Persistent failures stop
  playback with a message. The source keeps streaming across route changes
  and interruptions; only the engine graph is rebuilt.
- Verified against WEEI's Audacy HLS (packed AAC with ID3 headers and ad
  discontinuities), France Inter (MPEG-TS, 4 s segments), Apple's fMP4 and
  audio+video TS examples (byte ranges, init sections), NPR / NPO Icecast
  (MP3, HE-AAC), and a local origin that injects failing segments and
  sequence jumps. SAMPLE-AES and Ogg are reported as unsupported; old
  Shoutcast v1 servers that answer `ICY 200 OK` are untested.

Testing hook: launching with `-autoplay YES` (Xcode scheme argument, or
`xcrun simctl launch <udid> com.beloose.RadioSync -autoplay YES`) presses
Play on launch, so a stream can be exercised in the Simulator without
touching the screen.

## Project layout

```
RadioSync.xcodeproj/        Xcode project (folder-synchronized; new files are picked up automatically)
RadioSync/
  RadioSyncApp.swift        App entry point
  Info.plist                Background audio mode, mic usage string, portrait only
  Audio/                    Ring buffer, delay reader, engine, session, now-playing
  Sources/                  AudioSource implementations
  Sources/Streaming/        HLS playlist, MPEG-TS demuxer, decoder, pacer, StreamPipeline
  Model/                    PlayerModel
  UI/                       SwiftUI views (incl. the Stream URL sheet)
  Resources/TestPattern.wav Bundled test loop (regenerate with tools/make_test_pattern.py)
RadioSyncTests/             XCTest unit tests (ring, reader, sink, HLS parser, TS demuxer, decoder, pacer)
docs/                       Project spec
project.yml                 XcodeGen description, as a fallback (see below)
```

## If the project file won't open

`RadioSync.xcodeproj` was written by hand. Should Xcode reject it, regenerate
it from `project.yml`:

```
brew install xcodegen
xcodegen generate
```

That produces an equivalent project (same targets, settings, and folder
layout). Add the Team again under Signing & Capabilities afterwards.
