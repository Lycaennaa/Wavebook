import Foundation
import WavebookCore
extension MainViewController {
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
