import AppKit
import WavebookCore

extension StatisticsPageViewController {
    @objc func removeSelectedTimelineEntries() {
        guard !statisticsModel.isResetInFlight,
              let day = statisticsModel.selectedDay,
              let database = databaseProvider() else { return }
        let eventIDs = timelineEntries
            .filter { selectedTimelineEventIDs.contains($0.eventID) && $0.isFinalized }
            .map(\.eventID)
        guard !eventIDs.isEmpty else { return }

        do {
            let deletion = try database.deleteQualifiedListeningHistory(
                on: day,
                eventIDs: eventIDs,
                timeZone: timelineTimeZone
            )
            registerHistoryRemovalUndo(deletion, count: eventIDs.count)
            reloadAfterHistoryMutation()
        } catch {
            showHistoryRemovalError("Could not remove selected listening history.")
        }
    }

    private func reloadAfterHistoryMutation() {
        statisticsLoader.cancelDayAndTimeline()
        clearTimelineEntries()
        removeTimelineFailureNote()
        statisticsModel.setTimelineCursor(nil)
        loadMoreButton.isHidden = true
        refresh()
    }

    @objc func undoRemovalClicked() {
        performHistoryRemovalUndo(clearUndoManagerActions: true)
    }

    private func undoHistoryRemovalFromMenu() {
        performHistoryRemovalUndo(clearUndoManagerActions: false)
    }

    private func registerHistoryRemovalUndo(_ deletion: ListeningHistoryDeletion, count: Int) {
        clearHistoryRemovalUndo()
        historyDeletionUndo = deletion
        undoRemovalButton.title = count == 1 ? "Undo Remove" : "Undo Remove (\(count))"
        undoRemovalButton.isHidden = false

        let undoManager = view.window?.undoManager
        undoManager?.registerUndo(withTarget: self) { controller in
            controller.undoHistoryRemovalFromMenu()
        }
        undoManager?.setActionName("Remove Listening History")

        undoVisibilityGeneration += 1
        let generation = undoVisibilityGeneration
        undoVisibilityTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard let self, self.undoVisibilityGeneration == generation else { return }
            self.undoRemovalButton.isHidden = true
            self.undoVisibilityTask = nil
            self.layoutRegions()
        }
        layoutRegions()
    }

    private func performHistoryRemovalUndo(clearUndoManagerActions: Bool) {
        guard let deletion = historyDeletionUndo,
              let database = databaseProvider() else { return }
        do {
            try database.restoreListeningHistory(deletion)
            historyDeletionUndo = nil
            undoVisibilityTask?.cancel()
            undoVisibilityTask = nil
            undoVisibilityGeneration += 1
            undoRemovalButton.isHidden = true
            if clearUndoManagerActions {
                view.window?.undoManager?.removeAllActions(withTarget: self)
            }
            reloadAfterHistoryMutation()
        } catch {
            showHistoryRemovalError("Could not restore removed listening history.")
        }
    }

    func clearHistoryRemovalUndo() {
        undoVisibilityTask?.cancel()
        undoVisibilityTask = nil
        undoVisibilityGeneration += 1
        historyDeletionUndo = nil
        undoRemovalButton.isHidden = true
        view.window?.undoManager?.removeAllActions(withTarget: self)
        layoutRegions()
    }

    private func showHistoryRemovalError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        retryButton.isHidden = true
        errorRow.isHidden = false
        layoutRegions()
    }
}
