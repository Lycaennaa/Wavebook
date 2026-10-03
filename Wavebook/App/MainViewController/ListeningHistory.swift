import Foundation
import WavebookCore
extension MainViewController {
    func finalizeForTermination(completion: @escaping @MainActor (Bool) -> Void) {
        notifications.prepareForTermination()
        playbackSession.transport.finalizeForTermination { [weak self] succeeded in
            if !succeeded {
                self?.notifications.cancelTermination()
            }
            completion(succeeded)
        }
    }

    func applySavedPrivateMode() {
        guard let enabled = playbackSession.history.privateModeEnabled else { return }
        playerBar.setPrivateMode(enabled)
    }

    func togglePrivateMode() {
        guard playbackSession.history.privateModeEnabled != nil else { return }
        let succeeded = playbackSession.history.togglePrivateMode()
        playerBar.setPrivateMode(playbackSession.history.privateModeEnabled ?? false)
        if !succeeded {
            report(
                ListeningHistoryToggleError.privateModeRejected,
                message: "Could not change private listening mode"
            )
            return
        }
        if navigation.currentPage == .statistics {
            statisticsPage.refreshStatusOnly()
        }
    }

    func persistenceWarningDidChange(_ warning: String?) {
        if let warning {
            showPersistenceError(warning)
        } else {
            hidePersistenceError()
        }
        if navigation.currentPage == .statistics {
            statisticsPage.refreshStatusOnly()
        }
    }

    func showPersistenceError(_ message: String) {
        notifications.showPersistenceError(message)
    }

    func hidePersistenceError() {
        notifications.hidePersistenceError()
    }
}

private enum ListeningHistoryToggleError: LocalizedError {
    case privateModeRejected

    var errorDescription: String? {
        switch self {
        case .privateModeRejected:
            return "Private listening could not be changed because history writes are still recovering."
        }
    }
}
