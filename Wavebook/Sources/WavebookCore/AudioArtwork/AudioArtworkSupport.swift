import CryptoKit
import Foundation
import ImageIO

enum AudioArtworkLimits {
    static let sidecarNames: Set<String> = ["cover", "folder", "front"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff", "webp", "avif"]
    static let maximumSidecarCandidateCount = 64
    static let maximumArtworkBytes = 16 * 1_024 * 1_024
    static let maximumArtworkMetadataBytes = 64 * 1_024
    static let maximumEmbeddedScanBytes: UInt64 = 64 * 1_024 * 1_024
    static let maximumOpusPacketBytes = 24 * 1_024 * 1_024
    static let maximumOpusBase64Bytes = 23 * 1_024 * 1_024
    static let maximumReadChunkBytes = 1 * 1_024 * 1_024
    static let maximumPixelDimension: Int64 = 16_384
    static let maximumArtworkPixelCount: Int64 = 32 * 1_024 * 1_024
}

enum AudioArtworkImageSupport {
    static func isValidArtworkData(_ data: Data) -> Bool {
        guard !Task.isCancelled,
              !data.isEmpty,
              data.count <= AudioArtworkLimits.maximumArtworkBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        return !Task.isCancelled && isPixelAreaWithinBounds(width.int64Value, height.int64Value)
    }

    static func decodedArtworkImage(_ data: Data, maximumPixelSize: Int) -> CGImage? {
        guard maximumPixelSize > 0,
              !Task.isCancelled,
              isValidArtworkData(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              !Task.isCancelled,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: min(
                       maximumPixelSize,
                       Int(AudioArtworkLimits.maximumPixelDimension)
                   ),
                  kCGImageSourceShouldCache: false,
                  kCGImageSourceShouldCacheImmediately: false
              ] as CFDictionary),
              !Task.isCancelled else { return nil }
        return image
    }
    static func contentFingerprint(for data: Data) -> String? {
        guard data.count <= AudioArtworkLimits.maximumArtworkBytes else { return nil }
        var hasher = SHA256()
        var offset = 0
        while offset < data.count {
            guard !Task.isCancelled else { return nil }
            let end = min(offset + AudioArtworkLimits.maximumReadChunkBytes, data.count)
            hasher.update(data: data[offset..<end])
            offset = end
        }
        guard !Task.isCancelled else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func boundedArtworkData(at url: URL) -> Data? {
        let currentURL = URL(fileURLWithPath: url.path)
        guard let values = try? currentURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isReadable == true,
              let size = values.fileSize,
              size > 0,
              size <= AudioArtworkLimits.maximumArtworkBytes,
              let handle = try? FileHandle(forReadingFrom: currentURL) else { return nil }
        defer { try? handle.close() }
        guard !Task.isCancelled,
              let data = try? handle.read(upToCount: AudioArtworkLimits.maximumArtworkBytes + 1),
              data.count <= AudioArtworkLimits.maximumArtworkBytes else { return nil }
        return data
    }

    static func isPixelAreaWithinBounds(_ width: Int64, _ height: Int64) -> Bool {
        guard width > 0,
              height > 0,
              width <= AudioArtworkLimits.maximumPixelDimension,
              height <= AudioArtworkLimits.maximumPixelDimension else { return false }
        let pixelCount = width.multipliedReportingOverflow(by: height)
        return !pixelCount.overflow && pixelCount.partialValue <= AudioArtworkLimits.maximumArtworkPixelCount
    }
}

enum AudioArtworkFormatSupport {
    static func readData(
        from reader: inout BoundedFileReader,
        count: Int,
        maximumBytes: UInt64,
        maximumReadChunkBytes: Int
    ) -> Data? {
        guard count > 0,
              let countAsUInt64 = UInt64(exactly: count),
              countAsUInt64 <= maximumBytes,
              maximumReadChunkBytes > 0 else { return nil }
        var data = Data()
        data.reserveCapacity(count)
        var remaining = count
        while remaining > 0 {
            guard !Task.isCancelled else { return nil }
            let chunkSize = min(remaining, maximumReadChunkBytes)
            guard let chunk = reader.read(count: chunkSize) else { return nil }
            data.append(chunk)
            remaining -= chunkSize
        }
        return data
    }

    static func dataStarts(_ data: Data, with prefix: [UInt8]) -> Bool {
        data.count >= prefix.count && data.prefix(prefix.count).elementsEqual(prefix)
    }

    static func bigEndianUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 2 else { return nil }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    static func bigEndianUInt24(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 3 else { return nil }
        return UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
    }

    static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 4 else { return nil }
        return UInt32(data[offset]) << 24 |
            UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 |
            UInt32(data[offset + 3])
    }

    static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 4 else { return nil }
        return UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }

    static func synchsafeUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 4 else { return nil }
        let bytes = [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
        guard bytes.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }
        return UInt32(bytes[0]) << 21 | UInt32(bytes[1]) << 14 | UInt32(bytes[2]) << 7 | UInt32(bytes[3])
    }

    static func readBigEndianUInt32(from reader: inout BoundedFileReader) -> UInt32? {
        guard let data = reader.read(count: 4) else { return nil }
        return bigEndianUInt32(data, at: 0)
    }

    static func readBigEndianUInt32(from reader: inout BoundedFileReader, before end: UInt64) -> UInt32? {
        guard reader.offset + 4 <= end else { return nil }
        return readBigEndianUInt32(from: &reader)
    }

    static func readBigEndianUInt64(from reader: inout BoundedFileReader) -> UInt64? {
        guard let data = reader.read(count: 8) else { return nil }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    static func readBigEndianUInt32(_ data: Data, cursor: inout Int) -> UInt32? {
        guard let value = bigEndianUInt32(data, at: cursor) else { return nil }
        cursor += 4
        return value
    }

    static func isFourCC(_ data: Data, _ bytes: [UInt8]) -> Bool {
        data.count == bytes.count && data.elementsEqual(bytes)
    }

    static func dataMatches(_ data: Data, at offset: Int, bytes: [UInt8]) -> Bool {
        guard offset >= 0, offset <= data.count, data.count - offset >= bytes.count else { return false }
        return data[offset..<(offset + bytes.count)].elementsEqual(bytes)
    }

    static func bigEndianUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 8 else { return nil }
        return (0..<8).reduce(UInt64(0)) { result, index in
            (result << 8) | UInt64(data[offset + index])
        }
    }
}
