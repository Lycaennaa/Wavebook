import AppKit
import WavebookCore

extension MainViewController {
    func applySavedOutputDevice() {
        audioSettings.applySavedOutputDevice()
    }

    func showOutputDeviceMenu(from button: NSButton) {
        audioSettings.showOutputDeviceMenu(from: button)
    }

    func defaultOutputDeviceChanged() {
        audioSettings.defaultOutputDeviceChanged()
    }

    @discardableResult
    func selectOutputDevice(uid: String?) -> Bool {
        audioSettings.selectOutputDevice(uid: uid)
    }
}
