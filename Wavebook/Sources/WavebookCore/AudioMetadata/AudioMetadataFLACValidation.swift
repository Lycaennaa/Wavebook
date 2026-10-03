import Foundation

enum AudioMetadataFLACValidation {
    static func validate(from reader: inout BoundedFileReader, budget: inout AudioMetadataBudget) throws -> Bool {
        guard let signature = try reader.read(count: 4, budget: &budget),
              AudioMetadataBinarySupport.starts(signature, with: [0x66, 0x4C, 0x61, 0x43]) else { return false }
        var isLastBlock = false
        while !isLastBlock {
            try Task.checkCancellation()
            guard let blockHeader = try reader.read(count: 4, budget: &budget),
                  let blockLength = AudioMetadataBinarySupport.bigEndianUInt24(blockHeader, at: 1),
                  UInt64(blockLength) <= reader.limit - reader.offset else { return false }
            isLastBlock = blockHeader[0] & 0x80 != 0
            let blockBytes = UInt64(blockLength) + 4
            try budget.add(bytes: blockBytes, itemCount: 1)
            guard reader.skip(UInt64(blockLength)) else { return false }
        }
        return true
    }
}
