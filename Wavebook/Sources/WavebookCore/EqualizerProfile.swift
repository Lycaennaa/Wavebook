import Foundation

/// A persisted equalizer profile.
public struct EqualizerProfile: Codable, Equatable, Sendable {
    /// Device identifier associated with the profile.
    public static let defaultDeviceUID = "default"
    /// Minimum gain in decibels.
    public static let minimumGain = -12.0
    /// Maximum gain in decibels.
    public static let maximumGain = 12.0
    /// Center frequencies for the equalizer bands.
    public static let frequencies: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1_000, 1_250,
        1_600, 2_000, 2_500, 3_150, 4_000, 5_000, 6_300, 8_000, 10_000, 12_500, 16_000, 20_000
    ]
    /// Number of equalizer bands.
    public static let bandCount = frequencies.count

    /// Device identifier for this profile.
    public var deviceUID: String
    /// Preamp gain in decibels.
    public var preamp: Double
    /// Whether equalizer output is bypassed.
    public var isBypassed: Bool
    /// Gain values for each equalizer band.
    public private(set) var bandGains: [Double]

    /// Creates an equalizer profile with bounded gain values.
    public init(
        deviceUID: String = Self.defaultDeviceUID,
        preamp: Double = 0,
        isBypassed: Bool = true,
        bandGains: [Double] = Array(repeating: 0, count: Self.bandCount)
    ) {
        self.deviceUID = deviceUID.isEmpty ? Self.defaultDeviceUID : deviceUID
        self.preamp = Self.clampedGain(preamp)
        self.isBypassed = isBypassed
        self.bandGains = Self.normalizedBandGains(bandGains)
    }

    /// Creates a flat equalizer profile.
    public static func flat(deviceUID: String = Self.defaultDeviceUID) -> EqualizerProfile {
        EqualizerProfile(deviceUID: deviceUID)
    }

    private enum CodingKeys: String, CodingKey {
        case deviceUID, preamp, isBypassed, bandGains
    }

    /// Creates a profile by decoding persisted values.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            deviceUID: try values.decodeIfPresent(String.self, forKey: .deviceUID) ?? Self.defaultDeviceUID,
            preamp: try values.decodeIfPresent(Double.self, forKey: .preamp) ?? 0,
            isBypassed: try values.decodeIfPresent(Bool.self, forKey: .isBypassed) ?? true,
            bandGains: try values.decodeIfPresent([Double].self, forKey: .bandGains) ?? []
        )
    }

    /// Applies imported frequency/gain pairs to this profile.
    public func applyingImportedBands(_ text: String) throws -> EqualizerProfile {
        var gains = bandGains
        for (lineIndex, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let parts = line.split { $0 == "," || $0 == ";" || $0.isWhitespace }
            guard parts.count >= 2,
                  let frequency = Double(parts[0]), frequency.isFinite, frequency > 0,
                  let gain = Double(parts[1]), gain.isFinite else {
                throw EqualizerImportError.invalidLine(lineIndex + 1)
            }

            gains[Self.nearestBandIndex(to: frequency)] = gain
        }
        return EqualizerProfile(deviceUID: deviceUID, preamp: preamp, isBypassed: false, bandGains: gains)
    }

    /// Returns the index of the nearest equalizer band.
    public static func nearestBandIndex(to frequency: Double) -> Int {
        guard frequency.isFinite, frequency > 0 else { return 0 }
        guard frequency > frequencies[0] else { return 0 }
        guard frequency < frequencies[frequencies.count - 1] else { return frequencies.count - 1 }

        var lower = 0
        var upper = frequencies.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if frequencies[middle] < frequency {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        let lowerIndex = lower - 1
        let lowerDistance = abs(log(frequency / frequencies[lowerIndex]))
        let upperDistance = abs(log(frequency / frequencies[lower]))
        return lowerDistance <= upperDistance ? lowerIndex : lower
    }

    private static func normalizedBandGains(_ gains: [Double]) -> [Double] {
        let finite = gains.map(clampedGain)
        if finite.count == bandCount {
            return finite
        }
        if finite.count > bandCount {
            return Array(finite.prefix(bandCount))
        }
        return finite + Array(repeating: 0, count: bandCount - finite.count)
    }

    private static func clampedGain(_ gain: Double) -> Double {
        guard gain.isFinite else { return 0 }
        return min(max(gain, minimumGain), maximumGain)
    }
}

/// Errors raised while importing equalizer values.
public enum EqualizerImportError: Error, Equatable, Sendable {
    /// A line did not contain a valid frequency/gain pair.
    case invalidLine(Int)
}
