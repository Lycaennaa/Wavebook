import CoreAudio
import WavebookCore

@MainActor
final class PlaybackAudioOutputController {
    private let audioPlayer: AudioFilePlayer

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

    func setOutputDevice(id: AudioDeviceID) throws {
        try audioPlayer.setOutputDevice(id: id)
    }

    func apply(equalizerProfile: EqualizerProfile) {
        audioPlayer.apply(equalizerProfile: equalizerProfile)
    }
}
