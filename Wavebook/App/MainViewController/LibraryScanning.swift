import Foundation
import WavebookCore
extension MainViewController {

    func addRootFromOnboarding() -> Bool {
        libraryScan.addRoot()
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
