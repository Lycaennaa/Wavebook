import Foundation

enum AudioMetadataAPEValidation {
    static func validateHeader(from reader: inout BoundedFileReader, budget: inout AudioMetadataBudget) throws -> Bool {
        let start = reader.offset
        guard reader.limit - start >= 32,
              let header = try reader.read(count: 32, budget: &budget),
              AudioMetadataBinarySupport.starts(header, with: Array("APETAGEX".utf8)),
              let tagSize = AudioMetadataBinarySupport.littleEndianUInt32(header, at: 12),
              let itemCount = AudioMetadataBinarySupport.littleEndianUInt32(header, at: 16),
              let tagSize = UInt64(exactly: tagSize),
              let itemCount = Int(exactly: itemCount),
              tagSize >= 32,
              tagSize <= reader.limit - start else { return false }
        try budget.add(bytes: tagSize, itemCount: itemCount)
        return reader.seek(to: start + tagSize)
    }

    static func validateTail(
        from reader: inout BoundedFileReader,
        budget: inout AudioMetadataBudget,
        requireTag: Bool
    ) throws -> Bool {
        guard reader.limit >= 32 else { return !requireTag }
        guard reader.seek(to: reader.limit - 32),
              let footer = try reader.read(count: 32, budget: &budget) else { return false }
        guard AudioMetadataBinarySupport.starts(footer, with: Array("APETAGEX".utf8)) else { return !requireTag }
        guard let tagSize = AudioMetadataBinarySupport.littleEndianUInt32(footer, at: 12),
              let itemCount = AudioMetadataBinarySupport.littleEndianUInt32(footer, at: 16),
              let tagSize = UInt64(exactly: tagSize),
              let itemCount = Int(exactly: itemCount),
              tagSize >= 32,
              tagSize <= reader.limit else { return false }
        try budget.add(bytes: tagSize, itemCount: itemCount)
        return reader.seek(to: reader.limit)
    }
}
