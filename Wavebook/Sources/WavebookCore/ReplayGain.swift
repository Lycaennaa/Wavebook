import Foundation

/// Mode used to select replay-gain values.
public enum ReplayGainMode: String, CaseIterable, Codable, Sendable {
    /// Disable replay-gain adjustment.
    case off
    /// Use track-level gain.
    case track
    /// Use album-level gain with track fallback.
    case album

    /// Default replay-gain mode.
    public static let defaultValue = ReplayGainMode.off

    /// Next mode in the user-facing cycle.
    public var next: ReplayGainMode {
        switch self {
        case .off: .track
        case .track: .album
        case .album: .off
        }
    }
}

/// Source of a parsed or measured gain value.
public enum ReplayGainGainSource: String, Codable, Sendable {
    /// ReplayGain tag.
    case replayGain
    /// R128 tag.
    case r128
    /// Measured from audio.
    case measured
}

/// A gain value and its source.
public struct ReplayGainGain: Equatable, Sendable {
    /// Gain in decibels.
    public let decibels: Double
    /// Origin of the gain value.
    public let source: ReplayGainGainSource

    /// Creates a gain value.
    public init(decibels: Double, source: ReplayGainGainSource) {
        self.decibels = decibels
        self.source = source
    }
}
/// Normalized track- or album-level replay-gain values.
public struct ReplayGainScopeValues: Equatable, Sendable {
    /// Gain value, if available.
    public let gain: ReplayGainGain?
    /// Sample peak value, if available.
    public let samplePeak: Double?

    /// Creates normalized scope values.
    public init(gain: ReplayGainGain? = nil, samplePeak: Double? = nil) {
        self.gain = gain.flatMap { $0.decibels.isFinite ? $0 : nil }
        self.samplePeak = samplePeak.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// Whether both gain and peak values are available.
    public var isReady: Bool {
        gain != nil && samplePeak != nil
    }

    /// Fills missing values from a fallback scope.
    public func fillingMissing(from fallback: ReplayGainScopeValues) -> ReplayGainScopeValues {
        ReplayGainScopeValues(
            gain: gain ?? fallback.gain,
            samplePeak: samplePeak ?? fallback.samplePeak
        )
    }
}

/// Parsed track- and album-level replay-gain tags.
public struct ReplayGainTags: Equatable, Sendable {
    /// Track-level values.
    public var track: ReplayGainScopeValues?
    /// Album-level values.
    public var album: ReplayGainScopeValues?

    /// Creates parsed replay-gain tags.
    public init(track: ReplayGainScopeValues? = nil, album: ReplayGainScopeValues? = nil) {
        self.track = track
        self.album = album
    }
}

/// Namespace for ReplayGain analysis constants and calculations.
public enum ReplayGain {
    /// Target loudness, in LUFS, used by the analyzer.
    public static let targetLUFS = -18.0
    /// Maximum positive gain applied to a track, in decibels.
    public static let maximumBoostDB = 12.0
    /// Version of the ReplayGain analyzer implementation.
    public static let analyzerVersion = 1
    /// Version of the persisted ReplayGain tag schema.
    public static let tagSchemaVersion = 1
    /// Default maximum number of files analyzed concurrently.
    public static let defaultAnalysisFileConcurrency = 1
    /// Maximum number of files analyzed concurrently.
    public static let maximumAnalysisFileConcurrency = 15

    /// Clamps a requested analysis concurrency to supported bounds.
    public static func clampedAnalysisFileConcurrency(_ value: Int) -> Int {
        min(max(value, defaultAnalysisFileConcurrency), maximumAnalysisFileConcurrency)
    }

    /// Parses ReplayGain and R128 tags into normalized scope values.
    public static func parse(tags: [String: String]) -> ReplayGainTags {
        var normalized: [String: String] = [:]
        for (key, value) in tags {
            normalized[key.uppercased()] = value
        }

        return ReplayGainTags(
            track: scopeValues(
                replayGain: normalized["REPLAYGAIN_TRACK_GAIN"],
                peak: normalized["REPLAYGAIN_TRACK_PEAK"],
                r128: normalized["R128_TRACK_GAIN"]
            ),
            album: scopeValues(
                replayGain: normalized["REPLAYGAIN_ALBUM_GAIN"],
                peak: normalized["REPLAYGAIN_ALBUM_PEAK"],
                r128: normalized["R128_ALBUM_GAIN"]
            )
        )
    }

    static func isValidTagValue(_ value: String, for key: String) -> Bool {
        let tags = parse(tags: [key: value])

        switch key.uppercased() {
        case "REPLAYGAIN_TRACK_GAIN", "R128_TRACK_GAIN":
            return tags.track?.gain != nil
        case "REPLAYGAIN_TRACK_PEAK":
            return tags.track?.samplePeak != nil
        case "REPLAYGAIN_ALBUM_GAIN", "R128_ALBUM_GAIN":
            return tags.album?.gain != nil
        case "REPLAYGAIN_ALBUM_PEAK":
            return tags.album?.samplePeak != nil
        default:
            return false
        }
    }

    /// Calculates gain needed to reach the target loudness.
    public static func measuredGainDB(integratedLUFS: Double) -> Double? {
        guard integratedLUFS.isFinite else { return nil }
        return targetLUFS - integratedLUFS
    }

    /// Calculates available headroom for a sample peak.
    public static func headroomDB(samplePeak: Double) -> Double? {
        guard samplePeak.isFinite, samplePeak > 0 else { return nil }
        return -20 * log10(samplePeak)
    }

    /// Calculates the gain that can be safely applied to values.
    public static func appliedGainDB(for values: ReplayGainScopeValues?) -> Double? {
        guard
            let gainDB = values?.gain?.decibels,
            gainDB.isFinite,
            let samplePeak = values?.samplePeak,
            let headroomDB = headroomDB(samplePeak: samplePeak)
        else {
            return nil
        }

        return min(gainDB, maximumBoostDB, headroomDB)
    }

    /// Calculates applied gain for the selected scope.
    public static func appliedGainDB(
        mode: ReplayGainMode,
        track: ReplayGainScopeValues?,
        album: ReplayGainScopeValues?
    ) -> Double {
        switch mode {
        case .off:
            return 0
        case .track:
            return appliedGainDB(for: track) ?? 0
        case .album:
            return appliedGainDB(for: album) ?? appliedGainDB(for: track) ?? 0
        }
    }

    /// Returns the greatest valid sample peak in a sequence.
    public static func albumSamplePeak<S: Sequence>(_ peaks: S) -> Double? where S.Element == Double {
        peaks.lazy.filter { $0.isFinite && $0 > 0 }.max()
    }

    private static func scopeValues(replayGain: String?, peak: String?, r128: String?) -> ReplayGainScopeValues? {
        let gain = parseReplayGainDB(replayGain).map {
            ReplayGainGain(decibels: $0, source: .replayGain)
        } ?? parseR128GainDB(r128).map {
            ReplayGainGain(decibels: $0, source: .r128)
        }
        let samplePeak = parseSamplePeak(peak)

        guard gain != nil || samplePeak != nil else { return nil }
        return ReplayGainScopeValues(gain: gain, samplePeak: samplePeak)
    }

    private static func parseReplayGainDB(_ rawValue: String?) -> Double? {
        guard var value = trimmed(rawValue), !value.isEmpty else { return nil }
        if value.lowercased().hasSuffix("db") {
            value.removeLast(2)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let decibels = Double(value), decibels.isFinite else { return nil }
        return decibels
    }

    private static func parseR128GainDB(_ rawValue: String?) -> Double? {
        guard
            let value = trimmed(rawValue),
            let rawGain = Int(value),
            Int(Int16.min)...Int(Int16.max) ~= rawGain
        else {
            return nil
        }
        return Double(rawGain) / 256 + 5
    }

    private static func parseSamplePeak(_ rawValue: String?) -> Double? {
        guard
            let value = trimmed(rawValue),
            let peak = Double(value),
            peak.isFinite,
            peak > 0
        else {
            return nil
        }
        return peak
    }

    private static func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
