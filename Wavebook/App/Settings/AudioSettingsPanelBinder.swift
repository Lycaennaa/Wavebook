import AppKit
import WavebookCore

@MainActor
final class AudioSettingsPanelBinder {
    struct Configuration {
        let owner: NSViewController
        let devices: [OutputDevice]
        let selectedUID: String?
        let hiddenUIDs: Set<String>
        let playbackTransport: PlaybackTransportController
        let analysis: ReplayGainAnalysisCoordinator
        let onOutputDeviceChanged: (String?) -> Void
        let onHiddenOutputDeviceUIDsChanged: (Set<String>) -> Void
        let onSkipSilentSegmentsChanged: (Bool) -> Bool
        let reactivate: () -> Void
    }

    private var panel: SettingsPanelController?

    var isVisible: Bool {
        panel != nil
    }

    func configure(_ configuration: Configuration) {
        let panel = panel ?? SettingsPanelController()
        let analysis = configuration.analysis
        let playbackTransport = configuration.playbackTransport
        let onSkipSilentSegmentsChanged = configuration.onSkipSilentSegmentsChanged
        panel.onOutputDeviceChanged = configuration.onOutputDeviceChanged
        panel.onHiddenOutputDeviceUIDsChanged = configuration.onHiddenOutputDeviceUIDsChanged
        panel.onSkipSilentSegmentsChanged = { [weak panel] enabled in
            guard onSkipSilentSegmentsChanged(enabled) else {
                panel?.setSkipSilentSegments(playbackTransport.skipSilentSegments)
                return
            }
        }
        panel.onReplayGainAnalysisFileConcurrencyChanged = { [weak analysis, weak panel] value in
            analysis?.setFileConcurrency(value) { restoredValue in
                panel?.setReplayGainAnalysisFileConcurrency(restoredValue)
            }
        }
        panel.set(
            devices: configuration.devices,
            selectedUID: configuration.selectedUID,
            hiddenUIDs: configuration.hiddenUIDs
        )
        panel.setSkipSilentSegments(configuration.playbackTransport.skipSilentSegments)
        panel.setReplayGainAnalysisFileConcurrency(analysis.fileConcurrency)
        panel.setReplayGainService(analysis.service)
        self.panel = panel
        panel.showWindow(configuration.owner)
        panel.window?.makeKeyAndOrderFront(configuration.owner)
        configuration.reactivate()
    }

    func set(devices: [OutputDevice], selectedUID: String?, hiddenUIDs: Set<String>) {
        panel?.set(devices: devices, selectedUID: selectedUID, hiddenUIDs: hiddenUIDs)
    }

    func setSelectedOutputDeviceUID(_ uid: String?) {
        panel?.setSelectedOutputDeviceUID(uid)
    }

    func showReplayGainActionError(_ message: String) {
        panel?.showReplayGainActionError(message)
    }
}
