import WavebookCore

extension MainViewController {
    func startReplayGainAnalysis() {
        replayGainAnalysis.start()
    }

    func rescanLoudness(for tracks: [Track]) {
        replayGainAnalysis.rescanLoudness(for: tracks)
    }

    func rescanSelectedAlbumLoudness() {
        let key: AlbumKey?
        if case let .catalog(.albums(selectedAlbum)) = navigation.currentDestination {
            key = selectedAlbum
        } else {
            key = nil
        }
        replayGainAnalysis.rescanAlbum(key: key) { [weak self] in
            guard let self else { return false }
            if case let .catalog(.albums(selectedAlbum)) = self.navigation.currentDestination {
                return selectedAlbum == key
            }
            return false
        }
    }

    func applySavedReplayGainMode() {
        playbackSession.replayGain.applySavedMode()
    }

    func applySavedReplayGainAnalysisFileConcurrency() {
        replayGainAnalysis.applySavedFileConcurrency()
    }

    func cycleReplayGainMode() {
        _ = playbackSession.replayGain.cycleMode()
    }

    func showReplayGainActionError(_ message: String) {
        showSettings()
        audioSettings.showReplayGainActionError(message)
    }
}
