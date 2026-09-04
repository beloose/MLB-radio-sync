import AVFoundation
import Foundation

/// Owns the `AVAudioEngine` graph: an `AVAudioSourceNode` pulls delayed audio out
/// of the ring buffer through `DelayReader`, into the main mixer, out to whatever
/// the current route is (speaker, Bluetooth, AirPlay).
///
/// The ring buffer is fixed at 48 kHz mono regardless of the hardware route; the
/// main mixer resamples to the output. That keeps buffer positions meaningful
/// across route changes.
@MainActor
final class DelayEngine {

    static let sampleRate: Double = 48_000

    let ring: PCMRingBuffer
    let reader: DelayReader
    let sink: PCMSink
    let format: AVAudioFormat
    let maxDelaySeconds: Double

    /// Called on the main actor after the engine stopped itself because its I/O
    /// configuration changed (route or sample-rate change). Restart playback.
    var onConfigurationChange: (() -> Void)?
    /// Called on the main actor when the running source reports a fatal error.
    var onSourceFailure: ((Error) -> Void)?

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var configurationObserver: NSObjectProtocol?
    private var storedVolume: Float = 1

    var volume: Float {
        get { storedVolume }
        set {
            storedVolume = min(max(newValue, 0), 1)
            engine?.mainMixerNode.outputVolume = storedVolume
        }
    }

    var isRunning: Bool { engine?.isRunning ?? false }

    init(bufferSeconds: Double = 120, maxDelaySeconds: Double = 90, crossfadeSeconds: Double = 0.05) {
        let rate = Self.sampleRate
        let guardFrames = Int(rate)  // 1 s of headroom between reader and writer
        self.maxDelaySeconds = maxDelaySeconds
        ring = PCMRingBuffer(minimumCapacity: Int(bufferSeconds * rate) + guardFrames)
        reader = DelayReader(
            ring: ring,
            sampleRate: rate,
            maxDelayFrames: Int(maxDelaySeconds * rate),
            crossfadeFrames: Int(crossfadeSeconds * rate),
            guardFrames: guardFrames
        )
        sink = PCMSink(ring: ring, sampleRate: rate)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            preconditionFailure("could not build the engine format")
        }
        self.format = format
    }

    // MARK: Lifecycle

    /// Builds a fresh engine graph, starts `source` writing into the ring, and starts output.
    ///
    /// The session category must already be set (see `AudioSessionController.activate`).
    /// - Parameter anchor: true to start the delay fill from the source's first
    ///   frame (a fresh play); false to keep the current read position and just
    ///   re-establish the delay (restart after a route change or interruption).
    ///   On a restart, a source that doesn't `restartsWithEngine` is left running.
    func start(source: any AudioSource, anchor: Bool) throws {
        teardownEngine()

        // A fresh engine every time: once an engine has touched its input node it
        // keeps input enabled, which breaks a later start under the plain
        // `.playback` category. Rebuilding is cheap and avoids that state.
        let engine = AVAudioEngine()
        let reader = self.reader
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = buffers.first, let data = first.mData else { return noErr }
            let output = data.assumingMemoryBound(to: Float.self)
            let produced = reader.render(into: output, frameCount: Int(frameCount))
            isSilence.pointee = ObjCBool(!produced)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = storedVolume
        self.engine = engine
        self.sourceNode = node

        if anchor {
            reader.anchor(at: ring.writePosition)
        } else {
            reader.reanchor()
        }

        // Sources that tap the input node must do so before `prepare()`.
        let startsSource = anchor || source.restartsWithEngine
        if startsSource {
            let context = AudioSourceContext(engine: engine, sampleRate: Self.sampleRate) { [weak self] error in
                Task { @MainActor in self?.onSourceFailure?(error) }
            }
            try source.start(sink: sink, context: context)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            if startsSource { source.stop() }
            teardownEngine()
            throw error
        }
        observeConfigurationChanges(of: engine)
    }

    /// Stops output. Stop the active source first so its tap is removed from the engine.
    func stop() {
        teardownEngine()
    }

    // MARK: Delay control

    func setDelay(seconds: Double, reanchor: Bool = false) {
        reader.setDelay(frames: Int((seconds * Self.sampleRate).rounded()), reanchor: reanchor)
    }

    func setPaused(_ paused: Bool) {
        reader.setPaused(paused)
    }

    var snapshot: DelayReader.Snapshot { reader.snapshot }

    func seconds(fromFrames frames: Int) -> Double {
        Double(frames) / Self.sampleRate
    }

    // MARK: Private

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] notification in
            // Do not capture `engine` here: AVAudioEngine is not Sendable. Identify
            // the posting engine from the notification instead.
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine,
                      engine === (notification.object as AnyObject?) else { return }
                // The engine stops itself on a configuration change. If it is
                // running, this notification is stale (from a restart we did).
                guard !engine.isRunning else { return }
                self.onConfigurationChange?()
            }
        }
    }

    private func teardownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine?.stop()
        engine = nil
        sourceNode = nil
    }
}
