import WavebookCore

extension MainViewController {
    func applySavedEqualizer() {
        audioSettings.applySavedEqualizer()
    }

    func showEqualizer() {
        audioSettings.showEqualizer(owner: self) { [weak self] in
            self?.playbackSession.transport.refreshReplayGainDetails()
        }
    }

    func updateEqualizerReplayGainDetails() {
        playbackSession.transport.refreshReplayGainDetails()
    }
}
