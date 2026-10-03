import Foundation

enum AudioMetadataBinarySupport {
    static func starts(_ data: Data, with prefix: [UInt8], at offset: Int = 0) -> Bool {
        guard offset >= 0, offset <= data.count, prefix.count <= data.count - offset else { return false }
        return data[offset..<(offset + prefix.count)].elementsEqual(prefix)
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

    static func bigEndianUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 8 else { return nil }
        return data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    static func bigEndianUInt64(from reader: inout BoundedFileReader) -> UInt64? {
        guard let data = reader.read(count: 8) else { return nil }
        return bigEndianUInt64(data, at: 0)
    }

    static func synchsafeUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 4 else { return nil }
        let bytes = [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
        guard bytes.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }
        return UInt32(bytes[0]) << 21 | UInt32(bytes[1]) << 14 | UInt32(bytes[2]) << 7 | UInt32(bytes[3])
    }
}
