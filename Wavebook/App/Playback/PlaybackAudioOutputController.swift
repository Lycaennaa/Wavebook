import CoreAudio
import WavebookCore

@MainActor
final class PlaybackAudioOutputController {
    private let audioPlayer: AudioFilePlayer
    private(set) var activeOutputDeviceID: AudioDeviceID?
    private(set) var isBluetoothOutput: Bool?

    var onDefaultOutputDeviceChanged: (() -> Void)?

    init(audioPlayer: AudioFilePlayer) {
        self.audioPlayer = audioPlayer
        audioPlayer.onDefaultOutputDeviceChanged = { [weak self] in
            self?.onDefaultOutputDeviceChanged?()
        }
    }

    var volume: Float {
        get { audioPlayer.volume }
        set { audioPlayer.volume = newValue }
    }

    func startMonitoringDefaultOutputDevice() throws {
        try audioPlayer.startMonitoringDefaultOutputDevice()
    }

    func outputDeviceID() throws -> AudioDeviceID {
        try audioPlayer.outputDeviceID()
    }

    func setOutputDevice(id: AudioDeviceID, isBluetooth: Bool?) throws {
        do {
            try audioPlayer.setOutputDevice(id: id)
            activeOutputDeviceID = id
            isBluetoothOutput = isBluetooth
        } catch {
            if let outputError = error as? OutputDeviceError,
               case .routeRollbackFailed = outputError {
                activeOutputDeviceID = nil
                isBluetoothOutput = nil
            }
            throw error
        }
    }

    func reconcileOutputDevice(id: AudioDeviceID?, isBluetooth: Bool?) {
        activeOutputDeviceID = id
        isBluetoothOutput = isBluetooth
    }

    func apply(equalizerProfile: EqualizerProfile) {
        audioPlayer.apply(equalizerProfile: equalizerProfile)
    }
}
