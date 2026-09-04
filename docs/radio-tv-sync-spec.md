# Radio↔TV Sync App — Project Spec (iOS, phone-only)

## What we're building

A personal-use iPhone app that plays the Red Sox radio broadcast (WEEI feed via my MLB Audio subscription) through an adjustable delay buffer so it lines up perfectly with the TV broadcast. Manual sync first, then automatic sync using the phone's microphone.

**Who it's for:** Just me. Everything runs on the phone — no server, no Raspberry Pi, no cloud. My MLB credentials are stored only on the device.

**Why it exists:** Radio runs ahead of TV (cable/streaming pipeline delay). Today I manually pause the radio app and try to time it against the TV, but the app only skips in 10-second chunks. I want fine-grained control and eventually one-tap auto-sync.

## Platform and tooling

- **Native iOS app, Swift + SwiftUI.** Native networking (URLSession) has no CORS restrictions, so the phone can talk to MLB's endpoints directly — this is what makes the no-server design possible.
- Built with Claude Code + Xcode on my Mac, installed to my own iPhone via Xcode.
- Minimum iOS: current major version minus one. iPhone only, portrait.
- Use Accelerate/vDSP for the DSP in Phase 2 (FFT / cross-correlation primitives).

## Architecture (all on-device)

```
[MLB Audio servers]
   ↓ auth + game discovery + HLS segment downloads (URLSession)
[Segment fetcher/decoder] → [PCM ring buffer (~120s, mono)]
   ↓ read pointer = write pointer − delay
[AVAudioEngine: AVAudioPlayerNode → mixer → output]
   ↓
[Phone speaker / Bluetooth speaker / AirPlay]
```

**Own the audio pipeline end-to-end.** Do NOT play the stream with a plain AVPlayer — it gives no sample-level access for delay control. Instead:
1. Download the HLS audio playlist and its AAC segments ourselves
2. Decode segments to PCM (AVAssetReader or AudioFileStream + AudioConverter)
3. Write PCM into a ring buffer sized for ~120 seconds (mono to halve memory; ~23 MB at 48 kHz float32 — trivial)
4. An AVAudioSourceNode (or scheduled AVAudioPlayerNode buffers) reads from the ring buffer at (write position − delay)
5. Delay changes move the read pointer with a short crossfade (~50 ms) so nudges don't click

### Design principle: pluggable audio sources

Isolate stream acquisition behind a simple `AudioSource` protocol (start/stop, delivers PCM into the ring buffer, exposes metadata). Ship three conforming sources:
1. **MLB Audio** (primary) — auth + discovery + segment fetching
2. **Direct URL** — paste any HLS/Icecast stream URL
3. **Mic passthrough** — AVAudioEngine input node → ring buffer → delayed output (for using a physical radio; also the cheapest way to test the whole delay engine)

The MLB API is undocumented and changes. Keep every MLB-specific assumption in that one module so when it breaks, the fix is localized. Reference existing open-source MLB stream tools (e.g., mlbv and similar projects on GitHub) to understand the current auth/discovery flow, but implement it in our own Swift code.

## Phase 1 — Manual delay (the MVP)

**MLB module:**
- Login with my MLB account → session/access token, with refresh handling. Credentials + tokens in the Keychain, entered once in a Settings screen.
- Find today's Red Sox game via the MLB Stats API; list available radio feeds; default to the home/WEEI feed with a picker if multiple exist.
- Resolve the feed's HLS playback URL and start the segment fetch loop.

**Audio engine:**
- Ring buffer + delay read pointer as described above
- AVAudioSession category `.playback` (switching to `.playAndRecord` only during Phase 2 sync captures)
- **Background audio:** enable the Audio background mode so playback continues with the screen locked — this is a major reason to go native
- Lock screen / Control Center integration: MPNowPlayingInfoCenter (show game info) and MPRemoteCommandCenter (play/pause)
- Handle interruptions (phone call, Siri) and route changes (Bluetooth connect/disconnect) by pausing/resuming cleanly

**UI (dark, big touch targets):**
- Large readout of current delay in seconds (one decimal)
- Slider 0–90 s for coarse setting
- Buttons: −1 s / −0.1 s / +0.1 s / +1 s
- Play/stop, volume, source picker, game/feed info
- Persist last-used delay and source (UserDefaults); restore on launch
- Increasing delay means the buffer needs to fill — show a brief "buffering to +Xs" state instead of unexplained silence

**Acceptance:** I open the app, tap Play, hear the WEEI game feed, and nudge the delay in 0.1 s steps until the crack of the bat matches the TV. Playback survives screen lock. Delay survives an app relaunch.

## Phase 2 — Auto-sync via microphone

One button: **Sync to TV**.

**How it works:**
1. The ring buffer already holds the last ~120 s of radio audio — we can read any window of it
2. On tap: duck the app's own output (so the mic doesn't hear us), switch the session to `.playAndRecord`, capture ~10 s from the mic
3. The radio and TV have different announcers, so don't correlate raw waveforms. Compute an **onset/energy envelope** (or spectral flux) for both the mic capture and the corresponding ring-buffer window — the shared content is transient events: glove pop, bat crack, crowd surges, PA announcements
4. Cross-correlate the envelopes with vDSP (GCC-PHAT is the standard time-delay technique; normalized cross-correlation on onset envelopes is an acceptable first pass). Run it off the main thread
5. The lag of the correlation peak = how far the TV trails the radio. Set the delay accordingly, subtracting the output-path latency (`AVAudioSession.outputLatency` — this also compensates for Bluetooth speaker lag)
6. Restore `.playback`, un-duck, resume at the new delay

**Confidence handling:** If the correlation peak isn't clearly above the noise floor (define a ratio threshold), show "Couldn't lock on — try again during action" rather than applying a bad offset. Show a confidence indicator after each sync. Mic permission prompt appears on first use with a one-line explanation.

**Acceptance:** During a live game with the TV audible in the room, tapping Sync lands within ~0.2 s of perceptual sync most of the time, and gracefully refuses when it can't.

## Phase 3 — Polish + drift correction

- Optional periodic re-sync (every few minutes): short mic capture, recompute offset; correct drift by *slewing* the read pointer gradually instead of jumping
- Feed picker remembers preference (WEEI feed)
- Show score/inning from the Stats API data we already fetch
- App icon, haptics on the nudge buttons

## Testing hooks

- A "file mode" `AudioSource` that loops a bundled audio file, so the delay engine can be developed without a live game
- For correlation tests: generate two clips of the same base recording with different voice tracks overlaid and a known offset — unit test that the estimator recovers the offset within tolerance
- The mic-passthrough source doubles as a live end-to-end test any time (radio not required — any sound source works)

## Constraints and non-goals

- Personal use only, installed via Xcode on my own devices. Not for the App Store. Credentials stay on-device (Keychain).
- Don't delay the TV; only the radio. If the TV somehow runs ahead of the radio stream, I pause live TV briefly — the app just needs to make the radio side precise.
- No DVR/recording features. Live only.
- No accounts, no analytics, no network calls except MLB's.

## Suggested build order for Claude Code

1. Scaffold the Xcode project (SwiftUI app, background-audio capability, README with build/install steps)
2. Ring buffer + delay engine + UI, driven by the **mic passthrough** source ← proves the whole delay engine with zero networking
3. **Direct URL** source (HLS segment fetch → decode → ring buffer) using any public radio stream
4. **MLB module** (auth, game discovery, feed selection) behind the `AudioSource` protocol
5. Phase 2 auto-sync
6. Phase 3 polish
