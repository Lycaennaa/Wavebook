import AppKit
import CoreAudio
import OSLog
import WavebookCore

@MainActor
final class AudioSettingsCoordinator {
    private static let logger = Logger(subsystem: "Wavebook", category: "application")

    private let databaseProvider: () -> LibraryDatabase?
    private let audioOutput: PlaybackAudioOutputController
    private let playbackTransport: PlaybackTransportController
    private weak var playerBar: PlayerBarView?
    var onVolumeChanged: ((Float) -> Void)?
    private let onEvent: (PlaybackSessionEvent) -> Void

    private let outputDevices = OutputDeviceProvider()

    private(set) var selectedOutputDeviceUID: String?
    private(set) var hiddenOutputDeviceUIDs: Set<String> = []
    private(set) var equalizerProfile = EqualizerProfile.flat()
    private var equalizerProfileCanBeSaved = false
    private var equalizerPanel: EqualizerPanelController?
    private let settingsPanelBinder = AudioSettingsPanelBinder()

    var isEqualizerVisible: Bool {
        equalizerPanel != nil
    }

    init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        audioOutput: PlaybackAudioOutputController,
        playbackTransport: PlaybackTransportController,
        playerBar: PlayerBarView,
        onEvent: @escaping (PlaybackSessionEvent) -> Void
    ) {
        self.databaseProvider = databaseProvider
        self.audioOutput = audioOutput
        self.playbackTransport = playbackTransport
        self.playerBar = playerBar
        self.onEvent = onEvent
    }

    func applySavedVolume() {
        let volume: Float
        do {
            volume = try databaseProvider()?.volume() ?? 1
            clear(.database)
        } catch {
            volume = 1
            report(error, message: "Could not load saved volume", kind: .database)
        }
        audioOutput.volume = volume
        playerBar?.setVolume(volume)
        onVolumeChanged?(volume)
    }
    func applySavedVolume(_ volume: Float) {
        audioOutput.volume = volume
        playerBar?.setVolume(volume)
        onVolumeChanged?(volume)
    }

    func setVolume(_ volume: Float) {
        audioOutput.volume = volume
        playerBar?.setVolume(volume)
        onVolumeChanged?(volume)
        do {
            try databaseProvider()?.saveVolume(volume)
            clear(.database)
        } catch {
            report(error, message: "Could not save volume", kind: .database)
        }
    }

    func applySavedOutputDevice() {
        do {
            selectedOutputDeviceUID = try databaseProvider()?.selectedOutputDeviceUID()
            hiddenOutputDeviceUIDs = try databaseProvider()?.hiddenOutputDeviceUIDs() ?? []
            try applyOutputDevice(uid: selectedOutputDeviceUID)
            clear(.database)
            clear(.audioOutput)
        } catch {
            selectedOutputDeviceUID = nil
            do {
                try applyOutputDevice(uid: nil)
            } catch {
                report(error, message: "Could not restore system audio output", kind: .audioOutput)
            }
            report(error, message: "Saved audio output is unavailable; using system default", kind: .audioOutput)
        }
    }
    func applySavedOutputDevice(selectedUID: String?, hiddenUIDs: Set<String>) {
        selectedOutputDeviceUID = selectedUID
        hiddenOutputDeviceUIDs = hiddenUIDs
        do {
            try applyOutputDevice(uid: selectedUID)
            clear(.database)
            clear(.audioOutput)
        } catch {
            selectedOutputDeviceUID = nil
            do {
                try applyOutputDevice(uid: nil)
            } catch {
                report(error, message: "Could not restore system audio output", kind: .audioOutput)
            }
            report(error, message: "Saved audio output is unavailable; using system default", kind: .audioOutput)
        }
    }

    func startMonitoringDefaultOutputDevice() throws {
        try audioOutput.startMonitoringDefaultOutputDevice()
    }

    private func applyOutputDevice(uid: String?) throws {
        try audioOutput.setOutputDevice(id: resolvedOutputDevice(uid: uid).id)
    }
    private func resolvedOutputDevice(uid: String?) throws -> OutputDevice {
        if let uid {
            guard let device = try outputDevices.device(matchingUID: uid) else { throw OutputDeviceError.unavailable }
            return device
        }
        guard let device = try outputDevices.defaultOutputDevice() else { throw OutputDeviceError.unavailable }
        return device
    }

    private func activeEqualizerDevice() throws -> OutputDevice {
        let deviceID = try audioOutput.outputDeviceID()
        guard let device = try outputDevices.devices().first(where: { $0.id == deviceID }) else {
            throw OutputDeviceError.unavailable
        }
        return device
    }

    func showEqualizer(owner: NSViewController, refreshReplayGain: @escaping () -> Void) {
        let outputDeviceName: String
        do {
            outputDeviceName = try activeEqualizerDevice().name
            clear(.audioOutput)
        } catch {
            outputDeviceName = "Unavailable"
            report(error, message: "Could not determine the audio output for the equalizer", kind: .audioOutput)
        }

        if let equalizerPanel {
            equalizerPanel.setProfile(equalizerProfile, outputDeviceName: outputDeviceName)
            refreshReplayGain()
            equalizerPanel.showWindow(owner)
            equalizerPanel.window?.makeKeyAndOrderFront(owner)
            return
        }

        let panel = EqualizerPanelController(profile: equalizerProfile, outputDeviceName: outputDeviceName)
        panel.onChange = { [weak self] profile in
            guard let self else { return }
            do {
                guard self.equalizerProfileCanBeSaved,
                      let database = self.databaseProvider() else { throw OutputDeviceError.unavailable }
                try database.saveEqualizerProfile(profile)
                self.clear(.database)
                self.setEqualizerProfile(profile)
            } catch {
                self.equalizerPanel?.setProfile(self.equalizerProfile)
                self.report(error, message: "Could not save equalizer settings", kind: .database)
            }
        }
        panel.onReplayGainRefresh = refreshReplayGain
        equalizerPanel = panel
        refreshReplayGain()
        panel.showWindow(owner)
        panel.window?.makeKeyAndOrderFront(owner)
    }

    func setReplayGainDetails(_ details: ReplayGainPresentation) {
        equalizerPanel?.setReplayGainDetails(
            track: details.track,
            data: details.data,
            mode: details.mode,
            playbackGainDB: details.playbackGainDB,
            cacheError: details.cacheError
        )
    }

    func showSettings(
        owner: NSViewController,
        analysis: ReplayGainAnalysisCoordinator,
        reactivate: @escaping () -> Void
    ) {
        settingsPanelBinder.configure(.init(
            owner: owner,
            devices: visibleOutputDevices(),
            selectedUID: selectedOutputDeviceUID,
            hiddenUIDs: hiddenOutputDeviceUIDs,
            playbackTransport: playbackTransport,
            analysis: analysis,
            onOutputDeviceChanged: { [weak self] uid in
                _ = self?.selectOutputDevice(uid: uid)
            },
            onHiddenOutputDeviceUIDsChanged: { [weak self] uids in
                self?.hideOutputDevices(uids: uids)
            },
            onSkipSilentSegmentsChanged: { [weak self] enabled in
                self?.playbackTransport.setSkipSilentSegments(enabled) ?? false
            },
            reactivate: reactivate
        ))
    }

    func showReplayGainActionError(
        _ message: String,
        owner: NSViewController,
        analysis: ReplayGainAnalysisCoordinator,
        reactivate: @escaping () -> Void
    ) {
        Self.logger.error("ReplayGain action failed: \(message, privacy: .public)")
        showSettings(owner: owner, analysis: analysis, reactivate: reactivate)
        settingsPanelBinder.showReplayGainActionError(message)
    }

    private func report(_ error: Error, message: String, kind: OperationalErrorKind) {
        onEvent(.error(error, message: message, kind: kind))
    }

    private func clear(_ kind: OperationalErrorKind) {
        onEvent(.clearOperationalErrors(kind))
    }
}
extension AudioSettingsCoordinator {

    func defaultOutputDeviceChanged() {
        defer { refreshSettingsOutputDevices() }
        _ = selectOutputDevice(uid: nil)
    }

    private func refreshSettingsOutputDevices() {
        guard settingsPanelBinder.isVisible else { return }
        do {
            let devices = try outputDevices.devices().filter { !hiddenOutputDeviceUIDs.contains($0.uid) }
            settingsPanelBinder.set(
                devices: devices,
                selectedUID: selectedOutputDeviceUID,
                hiddenUIDs: hiddenOutputDeviceUIDs
            )
            clear(.audioOutput)
        } catch {
            settingsPanelBinder.setSelectedOutputDeviceUID(selectedOutputDeviceUID)
            report(error, message: "Could not refresh audio outputs", kind: .audioOutput)
        }
    }

    func visibleOutputDevices() -> [OutputDevice] {
        do {
            let devices = try outputDevices.devices().filter { !hiddenOutputDeviceUIDs.contains($0.uid) }
            clear(.audioOutput)
            return devices
        } catch {
            report(error, message: "Could not list audio outputs", kind: .audioOutput)
            return []
        }
    }

    @discardableResult
    func selectOutputDevice(uid: String?) -> Bool {
        let previousUID = selectedOutputDeviceUID
        let previousDeviceID: AudioDeviceID
        let targetDevice: OutputDevice
        let targetProfile: EqualizerProfile
        do {
            guard let database = databaseProvider() else { throw OutputDeviceError.unavailable }
            previousDeviceID = try audioOutput.outputDeviceID()
            targetDevice = try resolvedOutputDevice(uid: uid)
            targetProfile = try database.equalizerProfile(deviceUID: targetDevice.uid)
        } catch {
            report(error, message: "Could not load equalizer settings for the audio output", kind: .database)
            return false
        }

        do {
            try audioOutput.setOutputDevice(id: targetDevice.id)
        } catch {
            if let outputError = error as? OutputDeviceError,
               case .routeRollbackFailed = outputError {
                reconcileOutputAfterFailedRollback()
            } else {
                selectedOutputDeviceUID = previousUID
                refreshSettingsOutputDevices()
            }
            report(error, message: "Could not switch audio output", kind: .audioOutput)
            return false
        }

        do {
            guard let database = databaseProvider() else { throw OutputDeviceError.unavailable }
            try database.saveSelectedOutputDeviceUID(uid)
            clear(.database)
        } catch let saveError {
            do {
                try audioOutput.setOutputDevice(id: previousDeviceID)
                selectedOutputDeviceUID = previousUID
                refreshSettingsOutputDevices()
            } catch {
                reconcileOutputAfterFailedRollback()
                report(
                    error,
                    message: "Audio output changed, but the previous output could not be restored",
                    kind: .audioOutput
                )
            }
            report(saveError, message: "Could not save audio output selection", kind: .database)
            return false
        }

        selectedOutputDeviceUID = uid
        equalizerProfileCanBeSaved = true
        setEqualizerProfile(targetProfile, outputDeviceName: targetDevice.name)
        refreshSettingsOutputDevices()
        clear(.audioOutput)
        return true
    }

    private func reconcileOutputDeviceSelection() -> Bool {
        do {
            let outputDeviceID = try audioOutput.outputDeviceID()
            let defaultDeviceID = try OutputDeviceProvider.defaultOutputDeviceID()
            let uid: String?
            if outputDeviceID == defaultDeviceID {
                uid = nil
            } else {
                guard let device = try outputDevices.devices().first(where: { $0.id == outputDeviceID }) else {
                    throw OutputDeviceError.unavailable
                }
                uid = device.uid
            }
            selectedOutputDeviceUID = uid
            settingsPanelBinder.set(
                devices: visibleOutputDevices(),
                selectedUID: uid,
                hiddenUIDs: hiddenOutputDeviceUIDs
            )
            clear(.audioOutput)
            return true
        } catch {
            report(error, message: "Could not determine the active audio output", kind: .audioOutput)
            return false
        }
    }

    private func reconcileOutputAfterFailedRollback() {
        guard reconcileOutputDeviceSelection() else {
            equalizerProfileCanBeSaved = false
            equalizerPanel?.setProfile(equalizerProfile, outputDeviceName: "Unavailable")
            return
        }

        reconcileEqualizerForActiveOutput()
        do {
            guard let database = databaseProvider() else { throw OutputDeviceError.unavailable }
            try database.saveSelectedOutputDeviceUID(selectedOutputDeviceUID)
            clear(.database)
        } catch {
            report(
                error,
                message: "Could not save the reconciled audio output; restart will restore the last saved output",
                kind: .database
            )
        }
    }

    private func reconcileEqualizerForActiveOutput() {
        let device: OutputDevice
        do {
            device = try activeEqualizerDevice()
        } catch {
            equalizerProfileCanBeSaved = false
            equalizerPanel?.setProfile(equalizerProfile, outputDeviceName: "Unavailable")
            report(
                error,
                message: "Could not reconcile equalizer settings with the active audio output",
                kind: .audioOutput
            )
            return
        }

        do {
            guard let database = databaseProvider() else { throw OutputDeviceError.unavailable }
            let profile = try database.equalizerProfile(deviceUID: device.uid)
            equalizerProfileCanBeSaved = true
            setEqualizerProfile(profile, outputDeviceName: device.name)
            clear(.audioOutput)
            clear(.database)
        } catch {
            equalizerProfileCanBeSaved = false
            equalizerPanel?.setProfile(equalizerProfile, outputDeviceName: device.name)
            report(
                error,
                message: "Could not reconcile equalizer settings with the active audio output",
                kind: .database
            )
        }
    }

    @objc func selectOutputDeviceMenuItem(_ item: NSMenuItem) {
        let uid = item.representedObject as? String
        _ = selectOutputDevice(uid: uid?.isEmpty == false ? uid : nil)
    }

    @objc func hideSelectedOutputDevice() {
        guard let uid = selectedOutputDeviceUID else { return }
        var hidden = hiddenOutputDeviceUIDs
        hidden.insert(uid)
        hideOutputDevices(uids: hidden)
    }

    @objc func unhideAllOutputDevices() {
        hideOutputDevices(uids: [])
    }

    func hideOutputDevices(uids: Set<String>) {
        let previousSelectedUID = selectedOutputDeviceUID
        let switchesToDefault = previousSelectedUID.map(uids.contains) == true
        var defaultProfile: EqualizerProfile?
        var defaultDeviceName: String?
        if switchesToDefault {
            guard let defaultOutput = loadDefaultOutputForHide() else { return }
            defaultProfile = defaultOutput.profile
            defaultDeviceName = defaultOutput.device.name
            guard switchToDefaultOutput(defaultOutput.device) else { return }
        }

        do {
            guard let database = databaseProvider() else { throw OutputDeviceError.unavailable }
            if switchesToDefault {
                try database.saveOutputConfiguration(selectedUID: nil, hiddenUIDs: uids)
                selectedOutputDeviceUID = nil
                if let defaultProfile {
                    equalizerProfileCanBeSaved = true
                    setEqualizerProfile(defaultProfile, outputDeviceName: defaultDeviceName)
                }
            } else {
                try database.saveHiddenOutputDeviceUIDs(uids)
            }
            hiddenOutputDeviceUIDs = uids
        } catch {
            if switchesToDefault {
                do {
                    try applyOutputDevice(uid: previousSelectedUID)
                } catch {
                    reconcileOutputAfterFailedRollback()
                    report(error, message: "Could not restore audio output after hiding failed", kind: .audioOutput)
                }
            }
            report(error, message: "Could not save hidden audio outputs", kind: .database)
            return
        }
        settingsPanelBinder.set(
            devices: visibleOutputDevices(),
            selectedUID: selectedOutputDeviceUID,
            hiddenUIDs: hiddenOutputDeviceUIDs
        )
        clear(.database)
        clear(.audioOutput)
    }
    private func loadDefaultOutputForHide() -> (device: OutputDevice, profile: EqualizerProfile?)? {
        do {
            guard databaseProvider() != nil else { throw OutputDeviceError.unavailable }
            let device = try resolvedOutputDevice(uid: nil)
            let profile = try databaseProvider()?.equalizerProfile(deviceUID: device.uid)
            return (device, profile)
        } catch {
            report(error, message: "Could not load equalizer settings for the default audio output", kind: .database)
            return nil
        }

    }
    private func switchToDefaultOutput(_ device: OutputDevice) -> Bool {
        do {
            try audioOutput.setOutputDevice(id: device.id)
            return true
        } catch {
            if let outputError = error as? OutputDeviceError,
               case .routeRollbackFailed = outputError {
                reconcileOutputAfterFailedRollback()
            }
            report(error, message: "Could not switch audio output before hiding it", kind: .audioOutput)
            return false
        }
    }
    func applySavedEqualizer() {
        guard let database = databaseProvider() else {
            equalizerProfileCanBeSaved = false
            setEqualizerProfile(.flat())
            return
        }
        let activeUID: String
        do {
            activeUID = try activeEqualizerDevice().uid
            clear(.audioOutput)
        } catch {
            equalizerProfileCanBeSaved = false
            setEqualizerProfile(.flat())
            report(error, message: "Could not determine the audio output for equalizer settings", kind: .audioOutput)
            return
        }
        do {
            let profile = try database.migrateDefaultEqualizerProfile(toDeviceUID: activeUID)
                ?? database.equalizerProfile(deviceUID: activeUID)
            equalizerProfileCanBeSaved = true
            setEqualizerProfile(profile)
            clear(.database)
        } catch {
            equalizerProfileCanBeSaved = false
            setEqualizerProfile(.flat(deviceUID: activeUID))
            report(error, message: "Could not load equalizer settings", kind: .database)
        }
    }
    private func setEqualizerProfile(_ profile: EqualizerProfile, outputDeviceName: String? = nil) {
        equalizerProfile = profile
        audioOutput.apply(equalizerProfile: profile)
        playerBar?.setEqualizerEnabled(!profile.isBypassed)
        equalizerPanel?.setProfile(profile, outputDeviceName: outputDeviceName)
    }
}
