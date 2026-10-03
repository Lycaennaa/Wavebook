import Foundation

enum AudioArtworkContainer {
    case id3
    case flac
    case opus
    case iso
    case riff
    case aiff
    case caf
}

enum AudioContainerArtworkParser {
    static func container(for signature: Data) -> AudioArtworkContainer? {
        if AudioArtworkFormatSupport.dataStarts(signature, with: [0x49, 0x44, 0x33]) {
            return .id3
        }
        if AudioArtworkFormatSupport.dataStarts(signature, with: [0x66, 0x4C, 0x61, 0x43]) {
            return .flac
        }
        if AudioArtworkFormatSupport.dataStarts(signature, with: [0x4F, 0x67, 0x67, 0x53]) {
            return .opus
        }
        if isRIFF(signature) {
            return .riff
        }
        if isAIFF(signature) {
            return .aiff
        }
        if AudioArtworkFormatSupport.dataStarts(signature, with: [0x63, 0x61, 0x66, 0x66]) {
            return .caf
        }
        if isISO(signature) {
            return .iso
        }
        return nil
    }

    static func artworkData(
        from reader: inout BoundedFileReader,
        container: AudioArtworkContainer,
        maximumArtworkBytes: Int,
        maximumArtworkMetadataBytes: Int,
        maximumReadChunkBytes: Int
    ) -> Data? {
        guard maximumArtworkBytes > 0,
              maximumArtworkMetadataBytes >= 0,
              maximumReadChunkBytes > 0,
              let maximumID3Bytes = maximumID3ChunkBytes(
                  artworkBytes: maximumArtworkBytes,
                  metadataBytes: maximumArtworkMetadataBytes
              ) else { return nil }

        switch container {
        case .riff:
            return AudioRIFFArtworkReader.artworkData(
                from: &reader,
                maximumArtworkBytes: UInt64(maximumArtworkBytes),
                maximumID3Bytes: maximumID3Bytes,
                maximumReadChunkBytes: maximumReadChunkBytes
            )
        case .aiff:
            return AudioAIFFArtworkReader.artworkData(
                from: &reader,
                maximumArtworkBytes: UInt64(maximumArtworkBytes),
                maximumID3Bytes: maximumID3Bytes,
                maximumReadChunkBytes: maximumReadChunkBytes
            )
        case .caf:
            return AudioCAFArtworkReader.artworkData(
                from: &reader,
                maximumArtworkBytes: UInt64(maximumArtworkBytes),
                maximumID3Bytes: maximumID3Bytes,
                maximumReadChunkBytes: maximumReadChunkBytes
            )
        case .id3, .flac, .opus, .iso:
            return nil
        }
    }

    private static func maximumID3ChunkBytes(artworkBytes: Int, metadataBytes: Int) -> UInt64? {
        let (sum, overflow) = artworkBytes.addingReportingOverflow(metadataBytes)
        guard !overflow else { return nil }
        return UInt64(exactly: sum)
    }

    private static func isRIFF(_ data: Data) -> Bool {
        dataMatches(data, at: 0, bytes: [0x52, 0x49, 0x46, 0x46]) &&
            dataMatches(data, at: 8, bytes: [0x57, 0x41, 0x56, 0x45])
    }

    private static func isAIFF(_ data: Data) -> Bool {
        guard dataMatches(data, at: 0, bytes: [0x46, 0x4F, 0x52, 0x4D]) else { return false }
        return dataMatches(data, at: 8, bytes: [0x41, 0x49, 0x46, 0x46]) ||
            dataMatches(data, at: 8, bytes: [0x41, 0x49, 0x46, 0x43])
    }

    private static func isISO(_ data: Data) -> Bool {
        guard data.count >= 8,
              let atomSize = AudioArtworkFormatSupport.bigEndianUInt32(data, at: 0),
              isSupportedISOLeadingAtom(Data(data[4..<8])) else { return false }
        if atomSize == 0 || atomSize >= 8 { return true }
        guard atomSize == 1,
              data.count >= 16,
              let extendedSize = AudioArtworkFormatSupport.bigEndianUInt64(data, at: 8) else { return false }
        return extendedSize >= 16
    }

    private static func isSupportedISOLeadingAtom(_ type: Data) -> Bool {
        dataMatches(type, at: 0, bytes: [0x66, 0x74, 0x79, 0x70]) ||
            dataMatches(type, at: 0, bytes: [0x6D, 0x6F, 0x6F, 0x76]) ||
            dataMatches(type, at: 0, bytes: [0x66, 0x72, 0x65, 0x65]) ||
            dataMatches(type, at: 0, bytes: [0x77, 0x69, 0x64, 0x65]) ||
            dataMatches(type, at: 0, bytes: [0x6D, 0x64, 0x61, 0x74]) ||
            dataMatches(type, at: 0, bytes: [0x73, 0x6B, 0x69, 0x70]) ||
            dataMatches(type, at: 0, bytes: [0x75, 0x75, 0x69, 0x64]) ||
            dataMatches(type, at: 0, bytes: [0x6D, 0x6F, 0x6F, 0x66]) ||
            dataMatches(type, at: 0, bytes: [0x6D, 0x66, 0x72, 0x61]) ||
            dataMatches(type, at: 0, bytes: [0x73, 0x69, 0x64, 0x78]) ||
            dataMatches(type, at: 0, bytes: [0x73, 0x73, 0x69, 0x78]) ||
            dataMatches(type, at: 0, bytes: [0x73, 0x74, 0x79, 0x70]) ||
            dataMatches(type, at: 0, bytes: [0x70, 0x64, 0x69, 0x6E]) ||
            dataMatches(type, at: 0, bytes: [0x65, 0x6D, 0x73, 0x67]) ||
            dataMatches(type, at: 0, bytes: [0x70, 0x72, 0x66, 0x74]) ||
            dataMatches(type, at: 0, bytes: [0x6D, 0x65, 0x74, 0x61])
    }

    private static func dataMatches(_ data: Data, at offset: Int, bytes: [UInt8]) -> Bool {
        guard offset >= 0, offset <= data.count, data.count - offset >= bytes.count else { return false }
        return data[offset..<(offset + bytes.count)].elementsEqual(bytes)
    }

}
