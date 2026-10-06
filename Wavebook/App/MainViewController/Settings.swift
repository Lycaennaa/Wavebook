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
            libraryFolders: LibraryFolderSettingsActions(
                roots: { [weak self] in self?.libraryScan.libraryRoots() ?? [] },
                add: { [weak self] roots in self?.libraryScan.addRoots(roots) },
                remove: { [weak self] root in
                    guard let self else { return }
                    await self.libraryScan.removeRoot(root)
                }
            ),
            onStartOnboarding: { [weak self] in
                self?.onOnboardingRequested?()
            },
            reactivate: { [weak self] in self?.navigation.reactivateCurrentPage() }
        )
    }
}
