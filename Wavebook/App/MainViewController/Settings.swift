import Foundation
import WavebookCore

extension MainViewController {
    var selectedLibraryTrack: Track? {
        navigation.selectedTrack
    }

    var visibleLibraryTracks: [Track] {
        navigation.visibleTracks
    }

    func applySavedVolume() {
        audioSettings.applySavedVolume()
    }

    @objc func showSettings() {
        audioSettings.showSettings(
            owner: self,
            analysis: replayGainAnalysis,
            libraryFolders: libraryFolderSettingsActions,
            onStartOnboarding: { [weak self] in
                self?.onOnboardingRequested?()
            },
            reactivate: { [weak self] in self?.navigation.reactivateCurrentPage() }
        )
    }
}
