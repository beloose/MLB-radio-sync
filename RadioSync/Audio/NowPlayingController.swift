import MediaPlayer

/// Lock screen / Control Center integration: shows what is playing and routes
/// the play/pause/stop remote commands back to the player.
@MainActor
final class NowPlayingController {

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onToggle: (() -> Void)?
    var onStop: (() -> Void)?

    init() {
        let center = MPRemoteCommandCenter.shared()
        _ = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPlay?() }
            return .success
        }
        _ = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPause?() }
            return .success
        }
        _ = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onToggle?() }
            return .success
        }
        _ = center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onStop?() }
            return .success
        }
        for command in [center.nextTrackCommand, center.previousTrackCommand,
                        center.skipForwardCommand, center.skipBackwardCommand,
                        center.seekForwardCommand, center.seekBackwardCommand,
                        center.changePlaybackPositionCommand] {
            command.isEnabled = false
        }
    }

    func update(metadata: AudioSourceMetadata, isPlaying: Bool, delaySeconds: Double) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title,
            MPMediaItemPropertyArtist: String(format: "Delay %.1f s", delaySeconds),
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let subtitle = metadata.subtitle {
            info[MPMediaItemPropertyAlbumTitle] = subtitle
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
