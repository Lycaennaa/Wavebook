import Foundation
import WavebookCore
extension MainViewController {

    var libraryFolderSettingsActions: LibraryFolderSettingsActions {
        LibraryFolderSettingsActions(
            roots: { [weak self] in self?.libraryScan.libraryRoots() },
            add: { [weak self] roots in self?.libraryScan.addRoots(roots) },
            remove: { [weak self] root in
                guard let self else { return }
                await self.libraryScan.removeRoot(root)
            }
        )
    }

    @objc func addRoot() {
        libraryScan.addRoot()
    }

    func rescanPersistedRoots() {
        libraryScan.rescanPersistedRoots()
    }

    func reloadCurrentPage() {
        navigation.reloadCurrentPage()
    }
}
