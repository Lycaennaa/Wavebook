import Foundation

enum AudioMetadataChunkedValidation {
    static func validateRIFF(from reader: inout BoundedFileReader, budget: inout AudioMetadataBudget) throws -> Bool {
        guard let header = try reader.read(count: 12, budget: &budget),
              AudioMetadataBinarySupport.starts(header, with: [0x52, 0x49, 0x46, 0x46]),
              AudioMetadataBinarySupport.starts(header, with: [0x57, 0x41, 0x56, 0x45], at: 8),
              let declaredSize = AudioMetadataBinarySupport.littleEndianUInt32(header, at: 4),
              declaredSize >= 4,
              UInt64(declaredSize) <= reader.limit - 8 else { return false }

        let end = UInt64(declaredSize) + 8
        while reader.offset < end {
            try Task.checkCancellation()
            guard end - reader.offset >= 8,
                  let chunkHeader = try reader.read(count: 8, budget: &budget),
                  let chunkSize = AudioMetadataBinarySupport.littleEndianUInt32(chunkHeader, at: 4),
                  UInt64(chunkSize) <= end - reader.offset else { return false }
            let isAudio = AudioMetadataBinarySupport.starts(chunkHeader, with: [0x64, 0x61, 0x74, 0x61])
            try budget.add(itemCount: 1)
            if !isAudio { try budget.add(bytes: UInt64(chunkSize) + 8) }
            let chunkEnd = reader.offset + UInt64(chunkSize)
            guard reader.seek(to: chunkEnd) else { return false }
            if chunkSize & 1 != 0 {
                guard chunkEnd < end, reader.skip(1) else { return false }
            }
        }
        return reader.offset == end
    }

    static func validateAIFF(from reader: inout BoundedFileReader, budget: inout AudioMetadataBudget) throws -> Bool {
        guard let header = try reader.read(count: 12, budget: &budget),
              AudioMetadataBinarySupport.starts(header, with: [0x46, 0x4F, 0x52, 0x4D]),
              AudioMetadataBinarySupport.starts(header, with: [0x41, 0x49, 0x46, 0x46], at: 8) ||
               AudioMetadataBinarySupport.starts(header, with: [0x41, 0x49, 0x46, 0x43], at: 8),
              let declaredSize = AudioMetadataBinarySupport.bigEndianUInt32(header, at: 4),
              UInt64(declaredSize) >= 4,
              UInt64(declaredSize) <= reader.limit - 8 else { return false }

        let end = UInt64(declaredSize) + 8
        while reader.offset < end {
            try Task.checkCancellation()
            guard end - reader.offset >= 8,
                  let chunkHeader = try reader.read(count: 8, budget: &budget),
                  let chunkSize = AudioMetadataBinarySupport.bigEndianUInt32(chunkHeader, at: 4),
                  UInt64(chunkSize) <= end - reader.offset else { return false }
            let isAudio = AudioMetadataBinarySupport.starts(chunkHeader, with: [0x53, 0x53, 0x4E, 0x44])
            try budget.add(itemCount: 1)
            if !isAudio { try budget.add(bytes: UInt64(chunkSize) + 8) }
            let chunkEnd = reader.offset + UInt64(chunkSize)
            guard reader.seek(to: chunkEnd) else { return false }
            if chunkSize & 1 != 0 {
                guard chunkEnd < end, reader.skip(1) else { return false }
            }
        }
        return reader.offset == end
    }

    static func validateCAF(from reader: inout BoundedFileReader, budget: inout AudioMetadataBudget) throws -> Bool {
        guard let header = try reader.read(count: 8, budget: &budget),
              AudioMetadataBinarySupport.starts(header, with: [0x63, 0x61, 0x66, 0x66]) else { return false }

        while reader.offset < reader.limit {
            try Task.checkCancellation()
            guard reader.limit - reader.offset >= 12,
                  let chunkHeader = try reader.read(count: 12, budget: &budget),
                  let chunkSize = AudioMetadataBinarySupport.bigEndianUInt64(chunkHeader, at: 4) else { return false }
            let isAudio = AudioMetadataBinarySupport.starts(chunkHeader, with: [0x64, 0x61, 0x74, 0x61])
            try budget.add(itemCount: 1)
            if chunkSize == UInt64.max {
                guard isAudio, reader.seek(to: reader.limit) else { return false }
                break
            }
            guard chunkSize <= reader.limit - reader.offset,
                  chunkSize <= UInt64.max - 12 else { return false }
            if !isAudio { try budget.add(bytes: chunkSize + 12) }
            guard reader.skip(chunkSize) else { return false }
        }
        return reader.offset == reader.limit
    }
}
