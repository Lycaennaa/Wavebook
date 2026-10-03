import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

extension AudioFilePlayer {
    /// Sets the current output device.
    public func setOutputDevice(id: AudioDeviceID?) throws {
        let deviceID = try id ?? OutputDeviceProvider.defaultOutputDeviceID()
        guard let audioUnit = engine.outputNode.audioUnit else { throw OutputDeviceError.unavailable }
        let previousDeviceID = try readOutputDeviceID(audioUnit)
        guard previousDeviceID != deviceID else { return }

        var value = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &value,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw OutputDeviceError.audioHardware(status) }
        try verifyOutputDevice(audioUnit, expected: deviceID, previous: previousDeviceID)
    }

    private func verifyOutputDevice(
        _ audioUnit: AudioUnit,
        expected deviceID: AudioDeviceID,
        previous previousDeviceID: AudioDeviceID
    ) throws {
        do {
            let actual = try readOutputDeviceID(audioUnit)
            guard actual == deviceID else {
                throw OutputDeviceError.routeMismatch(expected: deviceID, actual: actual)
            }
        } catch {
            var rollbackDeviceID = previousDeviceID
            let rollbackStatus = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &rollbackDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard rollbackStatus == noErr else {
                throw OutputDeviceError.routeRollbackFailed(expected: previousDeviceID)
            }
            do {
                guard try readOutputDeviceID(audioUnit) == previousDeviceID else {
                    throw OutputDeviceError.routeRollbackFailed(expected: previousDeviceID)
                }
            } catch {
                throw OutputDeviceError.routeRollbackFailed(expected: previousDeviceID)
            }
            throw error
        }
    }
}
