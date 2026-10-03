import AppKit
import MediaPlayer
import WavebookCore

extension PlaybackTransportController {
    func updateProgress(notify: Bool = true) {
        let elapsed = readElapsedTime()
        lyrics.update(elapsed: elapsed)
        skipSegmentEditor?.setPlaybackState(elapsed, isPlaying: audioPlayer.isPlaying)
        lyrics.setPlaybackPosition(elapsed)
        updateNowPlaying(state: audioPlayer.isPlaying ? .playing : .paused)
        if notify {
            emitPresentationChanged()
        }
    }

    func startProgressTimer() {
        progress.start { [weak self] in
            self?.updateProgress()
        }
    }

    func updateNowPlaying(state: MPNowPlayingPlaybackState) {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        let elapsed = readElapsedTime()

        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistDisplay,
            MPMediaItemPropertyAlbumTitle: track.albumTitle,
            MPMediaItemPropertyPlaybackDuration: audioPlayer.duration > 0
                ? audioPlayer.duration
                : track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0
        ]
        center.playbackState = state

    }
    func emitPresentationChanged() {
        guard presentationSuppressionDepth == 0 else { return }
        onPresentationChanged?()
    }
}
