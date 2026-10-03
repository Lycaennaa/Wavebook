import AppKit
import WavebookCore

extension StatisticsPageViewController {
    @objc func resetClicked() {
        guard let tracker = trackerProvider(), statisticsModel.beginReset() else { return }
        let alert = NSAlert()
        alert.messageText = "Reset all listening history?"
        alert.informativeText = "This permanently deletes every play, skip, and listened-time record. "
            + "This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        // Sheet, not runModal(): a modal run loop would starve the tracker's
        // sampling timer and truncate rendered listening time during playback.
        refreshStatusOnly()
        guard let window = view.window else {
            statisticsModel.finishReset()
            refreshStatusOnly()
            return
        }
        alert.beginSheetModal(for: window) { [weak self, weak tracker] response in
            guard let self else { return }
            self.statisticsModel.finishReset()
            guard response == .alertFirstButtonReturn, let tracker else {
                self.refreshStatusOnly()
                return
            }
            self.performReset(tracker: tracker)
        }
    }

    private func performReset(tracker: ListeningHistoryTracker) {
        let succeeded = tracker.resetHistory(
            renderedPosition: renderedPositionProvider(),
            isPlaying: isPlayingProvider()
        )
        if succeeded {
            selectDay(nil)
            refreshStatusOnly()
            refresh()
        } else {
            refreshStatusOnly()
            errorLabel.stringValue = "Could not reset listening history."
            errorLabel.isHidden = false
            retryButton.isHidden = true
            errorRow.isHidden = false
            layoutRegions()
        }
    }
}
