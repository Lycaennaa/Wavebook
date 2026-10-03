import CoreAudio
import Foundation

/// A system audio output device.
public struct OutputDevice: Equatable, Hashable, Sendable {
    /// Core Audio device identifier.
    public var id: AudioDeviceID
    /// Stable device UID.
    public var uid: String
    /// Display name.
    public var name: String
    /// Whether this is the current default output.
    public var isDefault: Bool

    /// Creates an output-device value.
    public init(id: AudioDeviceID, uid: String, name: String, isDefault: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
    }
}

/// Errors raised while querying or routing output devices.
public enum OutputDeviceError: Error, Equatable, Sendable {
    /// Core Audio returned an error status.
    case audioHardware(OSStatus)
    /// No usable output device was available.
    case unavailable
    /// The requested route did not apply.
    case routeMismatch(expected: AudioDeviceID, actual: AudioDeviceID)
    /// Restoring the previous route failed.
    case routeRollbackFailed(expected: AudioDeviceID)
}

/// Provides sorted system output-device information.
public final class OutputDeviceProvider: Sendable {
    /// Creates an output-device provider.
    public init() {}

    /// Returns available output devices.
    public func devices() throws -> [OutputDevice] {
        let defaultID = try? Self.defaultOutputDeviceID()
        return try Self.deviceIDs()
            .filter(Self.hasOutputStreams)
            .compactMap { id in
                guard let uid = Self.stringProperty(kAudioDevicePropertyDeviceUID, for: id),
                      let name = Self.stringProperty(kAudioObjectPropertyName, for: id) else {
                    return nil
                }
                return OutputDevice(id: id, uid: uid, name: name, isDefault: id == defaultID)
            }
            .sorted(by: Self.devicePrecedes)
    }

    static func devicePrecedes(_ left: OutputDevice, _ right: OutputDevice) -> Bool {
        if left.isDefault != right.isDefault { return left.isDefault }

        let nameOrder = CatalogFacetOrdering.localizedNameComparison(left.name, right.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }

        let uidOrder = CatalogFacetOrdering.rawValueComparison(left.uid, right.uid)
        if uidOrder != .orderedSame { return uidOrder == .orderedAscending }
        return left.id < right.id
    }

    /// Returns the current default output device.
    public func defaultOutputDevice() throws -> OutputDevice? {
        let id = try Self.defaultOutputDeviceID()
        return try devices().first { $0.id == id }
    }

    /// Returns the output device matching a UID.
    public func device(matchingUID uid: String) throws -> OutputDevice? {
        try devices().first { $0.uid == uid }
    }

    /// Returns the current default output device identifier.
    public static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        )
        return id
    }

    private static func deviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        )
        var ids = Array(
            repeating: AudioDeviceID(0),
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        )
        return ids
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, for id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw OutputDeviceError.audioHardware(status) }
    }
}
