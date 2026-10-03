import Foundation
import ImageIO

/// Reads bounded embedded and sidecar artwork.
public struct AudioArtworkReader: Sendable {
    /// Creates an artwork reader.
    public init() {}

    /// Returns embedded artwork or the matching sidecar artwork.
    public func artworkData(for audioURL: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        if let embedded = embeddedArtworkData(for: audioURL) {
            guard !Task.isCancelled else { return nil }
            return embedded
        }
        guard !Task.isCancelled else { return nil }
        let sidecar = AudioArtworkSidecarReader.artworkData(for: audioURL)
        return Task.isCancelled ? nil : sidecar
    }

    /// Returns the matching sidecar artwork URL.
    public func sidecarArtworkURL(for audioURL: URL) -> URL? {
        AudioArtworkSidecarReader.artworkURL(for: audioURL)
    }

    /// Returns a fingerprint for embedded and sidecar artwork.
    public func artworkCacheFingerprint(for audioURL: URL) -> String {
        guard !Task.isCancelled else { return "cancelled" }
        let fileFingerprint = AudioArtworkSidecarReader.audioResourceFingerprint(for: audioURL)
        let embeddedFingerprint: String
        if let embeddedArtwork = embeddedArtworkData(for: audioURL) {
            guard let contentFingerprint = AudioArtworkImageSupport.contentFingerprint(
                for: embeddedArtwork
            ) else { return "cancelled" }
            embeddedFingerprint = "accepted:\(contentFingerprint)"
        } else {
            guard !Task.isCancelled else { return "cancelled" }
            embeddedFingerprint = "none"
        }
        let sidecarFingerprint = AudioArtworkSidecarReader.cacheFingerprint(for: audioURL)
        guard !Task.isCancelled else { return "cancelled" }
        return "\(fileFingerprint)|embedded:\(embeddedFingerprint)|\(sidecarFingerprint)"
    }

    /// Returns whether artwork bytes are valid and bounded.
    public static func isValidArtworkData(_ data: Data) -> Bool {
        AudioArtworkImageSupport.isValidArtworkData(data)
    }

    /// Decodes bounded artwork bytes to an image.
    public static func decodedArtworkImage(_ data: Data, maximumPixelSize: Int) -> CGImage? {
        AudioArtworkImageSupport.decodedArtworkImage(data, maximumPixelSize: maximumPixelSize)
    }

    private func embeddedArtworkData(for audioURL: URL) -> Data? {
        let currentURL = URL(fileURLWithPath: audioURL.path)
        guard let values = try? currentURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isReadable == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              let handle = try? FileHandle(forReadingFrom: currentURL) else { return nil }
        defer { try? handle.close() }

        var reader = BoundedFileReader(
            handle: handle,
            fileSize: UInt64(fileSize),
            limit: AudioArtworkLimits.maximumEmbeddedScanBytes
        )
        let signatureLength = Int(min(reader.limit, UInt64(16)))
        guard let signature = reader.read(count: signatureLength),
              reader.seek(to: 0),
              let container = AudioContainerArtworkParser.container(for: signature) else { return nil }

        switch container {
        case .id3:
            return AudioID3ArtworkReader.artworkData(from: &reader)
        case .flac:
            return AudioFLACArtworkReader.artworkData(from: &reader)
        case .opus:
            return AudioOpusArtworkReader.artworkData(from: &reader)
        case .iso:
            return AudioISOArtworkReader.artworkData(from: &reader)
        case .riff, .aiff, .caf:
            return AudioContainerArtworkParser.artworkData(
                from: &reader,
                container: container,
                maximumArtworkBytes: AudioArtworkLimits.maximumArtworkBytes,
                maximumArtworkMetadataBytes: AudioArtworkLimits.maximumArtworkMetadataBytes,
                maximumReadChunkBytes: AudioArtworkLimits.maximumReadChunkBytes
            )
        }
    }
}
