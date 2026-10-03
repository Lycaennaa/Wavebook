@preconcurrency import AVFoundation
import Foundation

/// Reads bounded metadata and replay-gain tags from audio files.
public struct AudioMetadataReader: Sendable {
    /// Creates a metadata reader.
    public init() {}
    private static let replayGainTagKeys: Set<String> = [
        "REPLAYGAIN_TRACK_GAIN",
        "REPLAYGAIN_TRACK_PEAK",
        "REPLAYGAIN_ALBUM_GAIN",
        "REPLAYGAIN_ALBUM_PEAK",
        "R128_TRACK_GAIN",
        "R128_ALBUM_GAIN"
    ]

    /// Reads a normalized track from an audio URL.
    public func track(for url: URL) async throws -> Track {
        let shouldLoadMetadata = try AudioMetadataPreflight.allowsAVFoundationMetadata(for: url)
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler(operation: {
            async let loadedDuration = Self.duration(for: asset)
            async let loadedItems = Self.metadataItems(for: asset, enabled: shouldLoadMetadata)
            async let loadedTracks = asset.loadTracks(withMediaType: .audio)
            let (duration, items, audioTracks) = try await (loadedDuration, loadedItems, loadedTracks)
            guard !audioTracks.isEmpty else { throw AudioMetadataError.noAudioTrack }
            guard duration.isFinite, duration >= 0 else { throw AudioMetadataError.invalidDuration }
            let tags = try await Self.tags(from: items)
            try Task.checkCancellation()
            return MetadataParser.track(
                for: url,
                duration: duration,
                tags: tags
            )
        }, onCancel: {
            asset.cancelLoading()
        })
    }

    /// Reads replay-gain tags from an audio URL.
    public func replayGainTags(for url: URL) async throws -> ReplayGainTags {
        let tags = try await replayGainTagValues(for: url)
        try Task.checkCancellation()
        return ReplayGain.parse(tags: tags)
    }

    func replayGainTagValues(for url: URL) async throws -> [String: String] {
        let shouldLoadMetadata = try AudioMetadataPreflight.allowsAVFoundationMetadata(for: url)
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler(operation: {
            let items = try await Self.metadataItems(for: asset, enabled: shouldLoadMetadata)
            try Task.checkCancellation()
            return try await Self.replayGainTagValues(from: items)
        }, onCancel: {
            asset.cancelLoading()
        })
    }

    private static func duration(for asset: AVURLAsset) async throws -> TimeInterval {
        let duration = try await asset.load(.duration)
        try Task.checkCancellation()
        return duration.seconds
    }

    private static func metadataItems(for asset: AVURLAsset, enabled: Bool) async throws -> [AVMetadataItem] {
        try Task.checkCancellation()
        guard enabled else { return [] }
        let commonMetadata = try await asset.load(.commonMetadata)
        try Task.checkCancellation()
        guard commonMetadata.count <= AudioMetadataLimits.maximumMetadataItemCount else {
            throw AudioMetadataError.tooManyMetadataItems
        }
        let metadata = try await asset.load(.metadata)
        try Task.checkCancellation()
        guard metadata.count <= AudioMetadataLimits.maximumMetadataItemCount,
              metadata.count <= AudioMetadataLimits.maximumMetadataItemCount - commonMetadata.count else {
            throw AudioMetadataError.tooManyMetadataItems
        }
        var items = commonMetadata
        items.append(contentsOf: metadata)
        try Task.checkCancellation()
        return items
    }

    private enum MetadataField {
        case albumArtist
        case albumTitle
        case genre
        case artist
        case title
    }

    static func tags(from items: [AVMetadataItem]) async throws -> MetadataParser.ParsedTags {
        try await tags(from: items, stringValueLoader: { item in
            try await stringValue(for: item)
        })
    }

    static func tags(
        from items: [AVMetadataItem],
        stringValueLoader: @escaping @Sendable (AVMetadataItem) async throws -> String?
    ) async throws -> MetadataParser.ParsedTags {
        guard items.count <= AudioMetadataLimits.maximumMetadataItemCount else {
            throw AudioMetadataError.tooManyMetadataItems
        }
        try Task.checkCancellation()
        var tags = MetadataParser.ParsedTags()
        var artists = BoundedMetadataField()
        var genres = BoundedMetadataField()
        for item in items {
            try Task.checkCancellation()
            guard let field = metadataField(for: keyCandidates(for: item)),
                  let value = try await boundedStringValue(for: item, loader: stringValueLoader) else {
                continue
            }
            appendTag(
                field: field,
                value: value,
                to: &tags,
                artists: &artists,
                genres: &genres
            )
        }
        try Task.checkCancellation()
        tags.artistDisplay = artists.value
        tags.genreDisplay = genres.value
        return tags
    }

    private static func appendTag(
        field: MetadataField,
        value: String,
        to tags: inout MetadataParser.ParsedTags,
        artists: inout BoundedMetadataField,
        genres: inout BoundedMetadataField
    ) {
        switch field {
        case .albumArtist:
            if tags.albumArtist == nil { tags.albumArtist = value }
        case .albumTitle:
            if tags.albumTitle == nil { tags.albumTitle = value }
        case .genre:
            genres.append(value)
        case .artist:
            artists.append(value)
        case .title:
            if tags.title == nil { tags.title = value }
        }
    }

    private static func metadataField(for keys: [String]) -> MetadataField? {
        if keys.contains(where: {
            $0.contains("albumartist") || $0.contains("album artist") || $0.contains("album_artist")
        }) {
            return .albumArtist
        }
        if keys.contains(where: { $0.contains("album") && !$0.contains("artist") }) {
            return .albumTitle
        }
        if keys.contains(where: { $0.contains("genre") || $0 == "type" }) {
            return .genre
        }
        if keys.contains(where: {
            $0.contains("artist") || $0.contains("author")
                || $0.contains("creator") || $0.contains("performer")
        }) {
            return .artist
        }
        if keys.contains(where: { $0.contains("title") && !$0.contains("album") }) {
            return .title
        }
        return nil
    }
    static func replayGainTagValues(from items: [AVMetadataItem]) async throws -> [String: String] {
        try await replayGainTagValues(from: items, stringValueLoader: { item in
            try await replayGainStringValue(for: item)
        })
    }

    static func replayGainTagValues(
        from items: [AVMetadataItem],
        stringValueLoader: @escaping @Sendable (AVMetadataItem) async throws -> String?
    ) async throws -> [String: String] {
        guard items.count <= AudioMetadataLimits.maximumMetadataItemCount else {
            throw AudioMetadataError.tooManyMetadataItems
        }
        try Task.checkCancellation()
        var tags: [String: String] = [:]

        for item in items {
            try Task.checkCancellation()
            let key = try await replayGainTagKey(for: item)
            try Task.checkCancellation()
            guard let key else { continue }
            let rawValue = try await stringValueLoader(item)
            try Task.checkCancellation()
            guard
                let rawValue,
                let value = AudioMetadataValueBounds.trimmed(rawValue),
                !value.isEmpty
            else {
                continue
            }

            if let existing = tags[key] {
                let existingIsValid = ReplayGain.isValidTagValue(existing, for: key)
                guard !existingIsValid, ReplayGain.isValidTagValue(value, for: key) else { continue }
            }
            tags[key] = value
        }

        try Task.checkCancellation()
        return tags
    }

    private static func keyCandidates(for item: AVMetadataItem) -> [String] {
        var candidates: [String] = []
        for value in [item.commonKey?.rawValue, item.identifier?.rawValue] {
            if let value {
                candidates.append(AudioMetadataValueBounds.key(value))
            }
        }
        if let key = item.key {
            let value: String?
            if let key = key as? String {
                value = key
            } else if let key = key as? NSString {
                value = key as String
            } else if let key = key as? NSNumber {
                value = key.stringValue
            } else {
                value = nil
            }
            if let value {
                candidates.append(AudioMetadataValueBounds.key(value))
            }
        }
        return candidates.filter { !$0.isEmpty }
    }

    private static func replayGainTagKey(for item: AVMetadataItem) async throws -> String? {
        let candidates = keyCandidates(for: item)

        if let key = replayGainTagKey(in: candidates) {
            return key
        }

        guard candidates.contains(where: { $0.uppercased().hasSuffix("TXXX") }) else { return nil }
        let attributes = try await extraAttributes(for: item)
        try Task.checkCancellation()
        guard let attributes,
              attributes.count <= AudioMetadataLimits.maximumExtraAttributeCount,
              let info = attributes.first(where: { $0.key.rawValue == "info" })?.value else { return nil }
        let infoString: String
        if let info = info as? String {
            infoString = info
        } else if let info = info as? NSString {
            infoString = info as String
        } else {
            return nil
        }
        return replayGainTagKey(in: [infoString])
    }
    private static func boundedStringValue(
        for item: AVMetadataItem,
        loader: (AVMetadataItem) async throws -> String?
    ) async throws -> String? {
        do {
            let value = try await loader(item)
            try Task.checkCancellation()
            guard let value else { return nil }
            return AudioMetadataValueBounds.trimmed(value)
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private static func replayGainTagKey(in candidates: [String?]) -> String? {
        for candidate in candidates.compactMap(\.self) {
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if replayGainTagKeys.contains(normalized) {
                return normalized
            }
            if let suffix = normalized.split(separator: "/").last, replayGainTagKeys.contains(String(suffix)) {
                return String(suffix)
            }
        }

        return nil
    }

    private static func stringValue(for item: AVMetadataItem) async throws -> String? {
        do {
            let value = try await item.load(.stringValue)
            try Task.checkCancellation()
            return value
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private static func replayGainStringValue(for item: AVMetadataItem) async throws -> String? {
        do {
            let value = try await item.load(.stringValue)
            try Task.checkCancellation()
            return value
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private static func extraAttributes(for item: AVMetadataItem) async throws -> [AVMetadataExtraAttributeKey: Any]? {
        do {
            let attributes = try await item.load(.extraAttributes)
            try Task.checkCancellation()
            return attributes
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}

/// Errors raised while reading audio metadata.
public enum AudioMetadataError: Error, Equatable, Sendable {
    /// The file contains no audio track.
    case noAudioTrack
    /// The file duration is invalid.
    case invalidDuration
    /// Metadata exceeded the safe byte bound.
    case metadataTooLarge
    /// Metadata contained too many items.
    case tooManyMetadataItems
}
