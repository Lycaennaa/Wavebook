import WavebookCore

extension MainViewController {
    func showLyrics() {
        playbackSession.transport.showLyrics(owner: self)
    }

    func showLyricsDownloadDialog(for track: Track) {
        playbackSession.transport.showDownloadDialog(for: track, owner: self)
    }
}
