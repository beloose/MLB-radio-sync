import AVFoundation

/// Configures `AVAudioSession` and relays interruptions and route changes.
@MainActor
final class AudioSessionController {

    enum Event {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case routeChanged(reason: AVAudioSession.RouteChangeReason)
        case mediaServicesReset
    }

    var onEvent: ((Event) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.mediaServicesReset) }
        })
    }

    /// Sets the category for the kind of source about to play and activates the session.
    ///
    /// `.playback` is the normal mode (background audio, lock-screen controls).
    /// `.playAndRecord` is only used while a source captures through the mic, and
    /// later for Phase 2 sync captures. Bluetooth A2DP and AirPlay stay allowed so
    /// a Bluetooth speaker keeps full quality while the built-in mic captures.
    func activate(needsMicrophone: Bool) throws {
        if needsMicrophone {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay])
        } else {
            try session.setCategory(.playback, mode: .default, options: [])
        }
        try? session.setPreferredSampleRate(DelayEngine.sampleRate)
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true, options: [])
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    var outputRouteName: String {
        session.currentRoute.outputs.map(\.portName).joined(separator: " + ")
    }

    var inputRouteName: String? {
        session.currentRoute.inputs.first?.portName
    }

    /// Output-path latency; Phase 2 subtracts this from the measured lag.
    var outputLatency: TimeInterval {
        session.outputLatency
    }

    // MARK: Private

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            onEvent?(.interruptionBegan)
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            onEvent?(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
        onEvent?(.routeChanged(reason: reason))
    }
}
