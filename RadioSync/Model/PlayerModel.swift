import AVFoundation
import Foundation
import Observation

/// Single source of truth for the UI: playback state, the delay, the selected
/// source, and persistence. Owns the engine and the session/lock-screen glue.
@MainActor
@Observable
final class PlayerModel {

    enum State: Equatable {
        case stopped
        case starting
        /// Waiting for the ring to hold `delaySeconds` of audio since the source started.
        case buffering(progress: Double)
        case playing
        /// Output frozen while the source keeps writing: the delay grows until resumed.
        case paused

        var isActive: Bool { self != .stopped && self != .starting }
    }

    private enum Keys {
        static let delay = "delaySeconds"
        static let volume = "volume"
        static let source = "sourceKind"
        static let streamURL = "streamURL"
    }

    private(set) var state: State = .stopped
    /// The effective delay: what the user set, plus any growth from pausing.
    private(set) var delaySeconds: Double
    /// Value shown while the slider is being dragged; applied on release.
    private(set) var scrubbingDelaySeconds: Double?
    private(set) var volume: Float
    private(set) var sourceKind: AudioSourceKind
    private(set) var metadata: AudioSourceMetadata
    private(set) var outputRouteName: String = ""
    private(set) var errorMessage: String?
    /// The URL the Stream URL source plays.
    private(set) var streamURL: URL?
    /// Drives the URL entry sheet.
    var isEditingStreamURL = false

    let availableSources: [AudioSourceKind]
    let delayRange: ClosedRange<Double> = 0...90

    private let engine: DelayEngine
    private let session = AudioSessionController()
    private let nowPlaying = NowPlayingController()
    private let sources: [AudioSourceKind: any AudioSource]
    private let urlSource: DirectURLSource
    @ObservationIgnored private var activeSource: (any AudioSource)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var playAfterURLEntry = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engine = DelayEngine(maxDelaySeconds: 90)

        let savedURL = defaults.string(forKey: Keys.streamURL).flatMap(URL.init(string:))
        streamURL = savedURL
        urlSource = DirectURLSource(url: savedURL)
        var built: [AudioSourceKind: any AudioSource] = [.directURL: urlSource, .microphone: MicPassthroughSource()]
        if let url = Bundle.main.url(forResource: "TestPattern", withExtension: "wav") {
            built[.fileLoop] = FileLoopSource(url: url, name: "Test pattern")
        }
        sources = built
        availableSources = AudioSourceKind.allCases.filter { built[$0] != nil }

        let savedDelay = defaults.object(forKey: Keys.delay) as? Double ?? 0
        delaySeconds = min(max(savedDelay, 0), 90)
        let savedVolume = defaults.object(forKey: Keys.volume) as? Double ?? 1
        volume = Float(min(max(savedVolume, 0), 1))
        let savedKind = defaults.string(forKey: Keys.source).flatMap(AudioSourceKind.init(rawValue:))
        let kind = savedKind.flatMap { built[$0] != nil ? $0 : nil } ?? .microphone
        sourceKind = kind
        metadata = built[kind]?.metadata ?? AudioSourceMetadata(title: "RadioSync")

        engine.volume = volume
        engine.setDelay(seconds: delaySeconds)
        wireCallbacks()
    }

    // MARK: Derived state for the UI

    var displayedDelay: Double { scrubbingDelaySeconds ?? delaySeconds }

    var statusText: String {
        switch state {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .buffering(let progress):
            delaySeconds < 0.05
                ? "Waiting for audio…"
                : String(format: "Buffering to +%.1f s · %d%%", delaySeconds, Int((progress * 100).rounded()))
        case .playing: "Playing"
        case .paused: "Paused · delay growing"
        }
    }

    // MARK: Transport

    func play() {
        guard state == .stopped else { return }
        guard let source = sources[sourceKind] else {
            errorMessage = "No source available."
            return
        }
        if sourceKind == .directURL, streamURL == nil {
            playAfterURLEntry = true
            isEditingStreamURL = true
            return
        }
        state = .starting
        errorMessage = nil
        Task { await startPlayback(with: source) }
    }

    func pause() {
        guard state.isActive, state != .paused else { return }
        engine.setPaused(true)
        state = .paused
        refreshNowPlaying()
    }

    func resume() {
        guard state == .paused else { return }
        if !engine.isRunning {
            // The system stopped the engine (interruption). Bring it back before un-pausing.
            guard restartEngine() else { return }
        }
        engine.setPaused(false)
        state = .playing
        refreshNowPlaying()
    }

    func stop() {
        teardown()
    }

    func togglePlayPause() {
        switch state {
        case .stopped: play()
        case .starting: break
        case .paused: resume()
        case .buffering, .playing: pause()
        }
    }

    // MARK: Delay

    func setDelay(_ seconds: Double) {
        let clamped = min(max(seconds, delayRange.lowerBound), delayRange.upperBound)
        delaySeconds = clamped
        engine.setDelay(seconds: clamped)
        defaults.set(clamped, forKey: Keys.delay)
        refreshNowPlaying()
    }

    func nudge(by step: Double) {
        setDelay(delaySeconds + step)
    }

    func scrub(to seconds: Double) {
        scrubbingDelaySeconds = seconds
    }

    func endScrub() {
        guard let seconds = scrubbingDelaySeconds else { return }
        scrubbingDelaySeconds = nil
        setDelay(seconds)
    }

    // MARK: Volume and source

    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        engine.volume = volume
        defaults.set(Double(volume), forKey: Keys.volume)
    }

    func selectSource(_ kind: AudioSourceKind) {
        guard kind != sourceKind, sources[kind] != nil else { return }
        let wasActive = state != .stopped
        if wasActive { teardown() }
        sourceKind = kind
        defaults.set(kind.rawValue, forKey: Keys.source)
        metadata = sources[kind]?.metadata ?? metadata
        if kind == .directURL, streamURL == nil {
            playAfterURLEntry = wasActive
            isEditingStreamURL = true
            return
        }
        if wasActive { play() }
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: Stream URL

    func editStreamURL() {
        playAfterURLEntry = false
        isEditingStreamURL = true
    }

    /// Accepts a pasted URL. Returns a message to show if it isn't usable.
    @discardableResult
    func setStreamURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter a URL." }
        var candidate = trimmed
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else {
            return "That doesn't look like an http(s) URL."
        }
        let changed = url != streamURL
        streamURL = url
        urlSource.url = url
        defaults.set(url.absoluteString, forKey: Keys.streamURL)
        isEditingStreamURL = false

        let shouldPlay = playAfterURLEntry
        playAfterURLEntry = false
        if sourceKind == .directURL {
            if state != .stopped {
                if changed {
                    teardown()
                    play()
                }
            } else if shouldPlay {
                play()
            }
            metadata = urlSource.metadata
        }
        return nil
    }

    func cancelStreamURLEntry() {
        playAfterURLEntry = false
        isEditingStreamURL = false
    }

    // MARK: Private

    private func wireCallbacks() {
        session.onEvent = { [weak self] event in self?.handle(event) }
        engine.onConfigurationChange = { [weak self] in
            guard let self, self.state.isActive else { return }
            _ = self.restartEngine()
        }
        engine.onSourceFailure = { [weak self] error in
            guard let self, self.state != .stopped else { return }
            self.teardown()
            self.errorMessage = "Stream stopped: \(error.localizedDescription)"
        }
        nowPlaying.onPlay = { [weak self] in self?.remotePlay() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onToggle = { [weak self] in self?.togglePlayPause() }
        nowPlaying.onStop = { [weak self] in self?.stop() }
    }

    private func remotePlay() {
        switch state {
        case .stopped: play()
        case .paused: resume()
        default: break
        }
    }

    private func startPlayback(with source: any AudioSource) async {
        if source.needsMicrophone {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                state = .stopped
                errorMessage = "Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone."
                return
            }
        }
        // Stop may have been tapped while the permission prompt was up.
        guard state == .starting else { return }

        do {
            try session.activate(needsMicrophone: source.needsMicrophone)
            try engine.start(source: source, anchor: true)
            activeSource = source
            state = .buffering(progress: 0)
            startPolling()
            refreshMetadata()
            refreshNowPlaying()
        } catch {
            teardown()
            errorMessage = "Couldn't start audio: \(error.localizedDescription)"
        }
    }

    /// Rebuilds the engine around the current source without losing the ring's
    /// history or the delay setting. Returns false (and stops) on failure.
    @discardableResult
    private func restartEngine() -> Bool {
        guard let source = activeSource else { return false }
        do {
            if source.restartsWithEngine { source.stop() }
            try session.activate(needsMicrophone: source.needsMicrophone)
            try engine.start(source: source, anchor: false)
            refreshMetadata()
            return true
        } catch {
            teardown()
            errorMessage = "Audio stopped: \(error.localizedDescription)"
            return false
        }
    }

    private func teardown() {
        pollTask?.cancel()
        pollTask = nil
        activeSource?.stop()
        engine.stop()
        activeSource = nil
        engine.setPaused(false)
        session.deactivate()
        nowPlaying.clear()
        state = .stopped
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.poll()
            }
        }
    }

    private func poll() {
        guard state.isActive else { return }
        let snapshot = engine.snapshot
        if snapshot.isSettled {
            let effective = engine.seconds(fromFrames: snapshot.delayFrames)
            if abs(effective - delaySeconds) > 0.0005 {
                delaySeconds = effective
                defaults.set(effective, forKey: Keys.delay)
            }
            if state != .paused {
                switch snapshot.phase {
                case .idle:
                    break
                case .filling:
                    state = .buffering(progress: snapshot.fillProgress)
                case .playing:
                    if state != .playing {
                        state = .playing
                        refreshNowPlaying()
                    }
                }
            }
        }
        refreshMetadata()
    }

    private func refreshMetadata() {
        let current = activeSource?.metadata ?? sources[sourceKind]?.metadata ?? AudioSourceMetadata(title: "RadioSync")
        let route = session.outputRouteName
        var changed = false
        if current != metadata {
            metadata = current
            changed = true
        }
        if route != outputRouteName {
            outputRouteName = route
            changed = true
        }
        if changed { refreshNowPlaying() }
    }

    private func refreshNowPlaying() {
        guard state.isActive else {
            nowPlaying.clear()
            return
        }
        nowPlaying.update(metadata: metadata, isPlaying: state != .paused, delaySeconds: delaySeconds)
    }

    private func handle(_ event: AudioSessionController.Event) {
        switch event {
        case .interruptionBegan:
            guard state.isActive else { return }
            resumeAfterInterruption = state != .paused
            state = .paused
            refreshNowPlaying()

        case .interruptionEnded(let shouldResume):
            guard state == .paused, activeSource != nil else { return }
            if shouldResume && resumeAfterInterruption {
                if restartEngine() {
                    engine.setPaused(false)
                    state = .playing
                    refreshNowPlaying()
                }
            }
            resumeAfterInterruption = false

        case .routeChanged(let reason):
            // Headphones unplugged / speaker went away: pause rather than blast the room.
            if reason == .oldDeviceUnavailable, state.isActive, state != .paused {
                pause()
            }
            refreshMetadata()

        case .mediaServicesReset:
            teardown()
            errorMessage = "The audio system was reset. Tap Play to continue."
        }
    }
}
