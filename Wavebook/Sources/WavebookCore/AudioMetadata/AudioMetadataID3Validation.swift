import Foundation

enum AudioMetadataID3Validation {
    static func validate(from reader: inout BoundedFileReader, budget: inout AudioMetadataBudget) throws -> Bool {
        guard let tagHeader = try readTagHeader(from: &reader, budget: &budget) else { return false }
        let majorVersion = tagHeader.bytes[3]
        let footerSize: UInt64 = majorVersion == 4 && tagHeader.bytes[5] & 0x10 != 0 ? 10 : 0
        let totalSize = UInt64(tagHeader.size) + 10 + footerSize
        guard totalSize <= reader.limit else { return false }
        try budget.add(bytes: totalSize)

        let tagEnd = reader.offset + UInt64(tagHeader.size)
        guard try skipExtendedHeaderIfPresent(
            from: &reader,
            header: tagHeader.bytes,
            majorVersion: majorVersion,
            tagEnd: tagEnd,
            budget: &budget
        ) else { return false }

        let frameHeaderSize = majorVersion == 2 ? 6 : 10
        guard try validateFrames(
            from: &reader,
            budget: &budget,
            tagEnd: tagEnd,
            majorVersion: majorVersion,
            frameHeaderSize: frameHeaderSize
        ) else { return false }
        guard reader.seek(to: tagEnd), skipFooter(from: &reader, size: footerSize) else { return false }
        return true
    }

    private struct TagHeader {
        let bytes: Data
        let size: UInt32
    }

    private static func readTagHeader(
        from reader: inout BoundedFileReader,
        budget: inout AudioMetadataBudget
    ) throws -> TagHeader? {
        guard let header = try reader.read(count: 10, budget: &budget),
              AudioMetadataBinarySupport.starts(header, with: [0x49, 0x44, 0x33]),
              (2...4).contains(Int(header[3])),
              let tagSize = AudioMetadataBinarySupport.synchsafeUInt32(header, at: 6) else { return nil }
        return TagHeader(bytes: header, size: tagSize)
    }

    private static func skipExtendedHeaderIfPresent(
        from reader: inout BoundedFileReader,
        header: Data,
        majorVersion: UInt8,
        tagEnd: UInt64,
        budget: inout AudioMetadataBudget
    ) throws -> Bool {
        guard header[5] & 0x40 != 0 else { return true }
        guard reader.offset + 4 <= tagEnd,
              let sizeData = try reader.read(count: 4, budget: &budget),
              let size = extendedHeaderSize(from: sizeData, majorVersion: majorVersion),
              size <= tagEnd - reader.offset else { return false }
        return reader.skip(size)
    }

    private static func extendedHeaderSize(from data: Data, majorVersion: UInt8) -> UInt64? {
        if majorVersion == 4 {
            guard let size = AudioMetadataBinarySupport.synchsafeUInt32(data, at: 0), size >= 4 else { return nil }
            return UInt64(size - 4)
        }
        guard let size = AudioMetadataBinarySupport.bigEndianUInt32(data, at: 0) else { return nil }
        return UInt64(size)
    }

    private static func skipFooter(from reader: inout BoundedFileReader, size: UInt64) -> Bool {
        guard size > 0 else { return true }
        return reader.skip(size)
    }

    private static func validateFrames(
        from reader: inout BoundedFileReader,
        budget: inout AudioMetadataBudget,
        tagEnd: UInt64,
        majorVersion: UInt8,
        frameHeaderSize: Int
    ) throws -> Bool {
        while reader.offset < tagEnd {
            try Task.checkCancellation()
            if tagEnd - reader.offset < UInt64(frameHeaderSize) {
                guard let paddingLength = Int(exactly: tagEnd - reader.offset),
                      let padding = try reader.read(count: paddingLength, budget: &budget),
                      padding.allSatisfy({ $0 == 0 }) else { return false }
                return true
            }
            guard let frameHeader = try reader.read(count: frameHeaderSize, budget: &budget) else { return false }
            if frameHeader.allSatisfy({ $0 == 0 }) { return true }
            guard let frameSize = frameSize(in: frameHeader, majorVersion: majorVersion),
                  frameSize <= tagEnd - reader.offset else { return false }
            try budget.add(itemCount: 1)
            guard reader.skip(frameSize) else { return false }
        }
        return true
    }

    private static func frameSize(in header: Data, majorVersion: UInt8) -> UInt64? {
        if majorVersion == 2 {
            guard let size = AudioMetadataBinarySupport.bigEndianUInt24(header, at: 3) else { return nil }
            return UInt64(size)
        }
        if majorVersion == 3 {
            guard let size = AudioMetadataBinarySupport.bigEndianUInt32(header, at: 4) else { return nil }
            return UInt64(size)
        }
        guard let size = AudioMetadataBinarySupport.synchsafeUInt32(header, at: 4) else { return nil }
        return UInt64(size)
    }

}
