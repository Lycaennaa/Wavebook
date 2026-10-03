import Foundation

/// Parses bounded metadata values.
public enum MetadataParser {
    /// Parsed, bounded metadata tags.
    public struct ParsedTags: Equatable, Sendable {
        /// Optional title tag.
        public var title: String?
        /// Optional artist tag.
        public var artistDisplay: String?
        /// Optional album title tag.
        public var albumTitle: String?
        /// Optional album artist tag.
        public var albumArtist: String?
        /// Optional genre tag.
        public var genreDisplay: String?

        /// Creates parsed tags with optional fields.
        public init(
            title: String? = nil,
            artistDisplay: String? = nil,
            albumTitle: String? = nil,
            albumArtist: String? = nil,
            genreDisplay: String? = nil
        ) {
            self.title = title
            self.artistDisplay = artistDisplay
            self.albumTitle = albumTitle
            self.albumArtist = albumArtist
            self.genreDisplay = genreDisplay
        }
    }

    private struct BoundedListAccumulator {
        var result: [String] = []
        var component = String()
        var componentLength = 0
        var totalLength = 0

        mutating func appendComponent() -> Bool {
            guard result.count < AudioMetadataLimits.maximumMergedValueCount else { return false }
            guard let trimmed = AudioMetadataValueBounds.trimmed(component), !trimmed.isEmpty else { return true }
            let separatorLength = result.isEmpty ? 0 : 2
            let remainingLength = AudioMetadataLimits.maximumMergedValueLength - totalLength - separatorLength
            guard remainingLength > 0,
                  let bounded = AudioMetadataValueBounds.trimmed(trimmed, maximumLength: remainingLength) else {
                return false
            }
            result.append(bounded)
            totalLength += separatorLength + bounded.count
            return true
        }
    }

    /// Splits and bounds a delimited metadata value.
    public static func splitList(_ value: String) -> [String] {
        var accumulator = BoundedListAccumulator()
        accumulator.component.reserveCapacity(AudioMetadataLimits.maximumMetadataValueLength)
        for character in value {
            if character == "," || character == ";" {
                guard accumulator.appendComponent() else { break }
                accumulator.component.removeAll(keepingCapacity: true)
                accumulator.componentLength = 0
            } else if accumulator.componentLength < AudioMetadataLimits.maximumMetadataValueLength {
                accumulator.component.append(character)
                accumulator.componentLength += 1
            }
        }
        if accumulator.result.count < AudioMetadataLimits.maximumMergedValueCount {
            _ = accumulator.appendComponent()
        }
        return accumulator.result
    }

    /// Builds a bounded track from metadata tags.
    public static func track(for url: URL, duration: TimeInterval, tags: ParsedTags = ParsedTags()) -> Track {
        let fallbackTitle = String(
            url.deletingPathExtension().lastPathComponent.prefix(AudioMetadataLimits.maximumMetadataValueLength)
        )
        return Track(
            path: url.path,
            title: AudioMetadataValueBounds.trimmed(tags.title ?? "") ?? fallbackTitle,
            artistDisplay: AudioMetadataValueBounds.trimmed(tags.artistDisplay ?? "") ?? "",
            albumTitle: AudioMetadataValueBounds.trimmed(tags.albumTitle ?? "") ?? "",
            albumArtist: AudioMetadataValueBounds.trimmed(tags.albumArtist ?? ""),
            genreDisplay: AudioMetadataValueBounds.trimmed(tags.genreDisplay ?? "") ?? "",
            duration: duration.isFinite && duration > 0 ? duration : 0,
            format: AudioFormatSupport.normalizedExtension(for: url)
        )
    }
}
