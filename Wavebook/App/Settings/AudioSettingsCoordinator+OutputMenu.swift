import AppKit
import WavebookCore

extension AudioSettingsCoordinator {
    func showOutputDeviceMenu(from button: NSButton) {
        let menu = NSMenu()
        let defaultItem = NSMenuItem(
            title: "System Default",
            action: #selector(selectOutputDeviceMenuItem(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.representedObject = ""
        defaultItem.state = selectedOutputDeviceUID == nil ? .on : .off
        menu.addItem(defaultItem)

        let devices = visibleOutputDevices()
        if !devices.isEmpty {
            menu.addItem(.separator())
        }
        for device in devices {
            let item = NSMenuItem(
                title: device.isDefault ? "\(device.name) (Default)" : device.name,
                action: #selector(selectOutputDeviceMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.uid
            item.state = selectedOutputDeviceUID == device.uid ? .on : .off
            menu.addItem(item)
        }

        if selectedOutputDeviceUID != nil || !hiddenOutputDeviceUIDs.isEmpty {
            menu.addItem(.separator())
        }
        if selectedOutputDeviceUID != nil {
            let item = NSMenuItem(
                title: "Hide Selected Output",
                action: #selector(hideSelectedOutputDevice),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }
        if !hiddenOutputDeviceUIDs.isEmpty {
            let item = NSMenuItem(
                title: "Unhide All Outputs",
                action: #selector(unhideAllOutputDevices),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
    func defaultOutputDeviceChanged() {
        defer { refreshSettingsOutputDevices() }
        let disconnectObservedAt = ProcessInfo.processInfo.systemUptime
        let previousOutputDeviceID = audioOutput.activeOutputDeviceID
        let previousOutputWasBluetooth = audioOutput.isBluetoothOutput == true
        let selectionSucceeded = selectOutputDevice(uid: nil)
        if !selectionSucceeded, audioOutput.isBluetoothOutput == true {
            _ = reconcileOutputDeviceSelection()
        }
        let previousOutputIsAvailable = previousOutputDeviceID.flatMap {
            try? outputDevices.isDeviceAvailable(id: $0)
        }
        let isBluetoothDisconnect = BluetoothDisconnectDetection.isBluetoothDisconnect(
            activeOutputIsBluetooth: previousOutputWasBluetooth,
            defaultOutputIsBluetooth: try? outputDevices.defaultOutputDevice()?.isBluetooth,
            activeOutputDeviceIsAvailable: previousOutputIsAvailable,
            reconciledOutputIsBluetooth: audioOutput.isBluetoothOutput
        )
        if isBluetoothDisconnect {
            playbackTransport.noteBluetoothOutputDisconnect(at: disconnectObservedAt)
        }
    }
    func noteMediaKeyPause(at timestamp: TimeInterval?) {
        playbackTransport.noteMediaKeyPause(at: timestamp)
    }
}
