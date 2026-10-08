import WavebookCore

struct OutputDeviceSettings {
    let device: OutputDevice
    let equalizerProfile: EqualizerProfile
    let volume: Float
}

enum OutputDeviceVolumeRouting {
    static func outputDeviceUID(selectedOutputUID: String?, defaultOutputUID: String?) -> String? {
        selectedOutputUID ?? defaultOutputUID
    }
}
