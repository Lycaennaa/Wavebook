import Foundation

enum AudioID3ArtworkReader {
    static func artworkData(from reader: inout BoundedFileReader, end: UInt64? = nil) -> Data? {
        let parseEnd = end ?? reader.limit
        guard reader.offset <= parseEnd, parseEnd - reader.offset >= 10 else { return nil }
        guard let header = reader.read(count: 10),
              header[0] == 0x49,
              header[1] == 0x44,
              header[2] == 0x33 else { return nil }
        guard let tagSize = AudioArtworkFormatSupport.synchsafeUInt32(header, at: 6),
              UInt64(tagSize) <= parseEnd - reader.offset else { return nil }
        let majorVersion = header[3]
        guard (2...4).contains(Int(majorVersion)) else { return nil }

        let tagEnd = reader.offset + UInt64(tagSize)
        let tagFlags = header[5]
        if tagFlags & 0x40 != 0 {
            guard skipExtendedHeader(from: &reader, majorVersion: majorVersion, end: tagEnd) else { return nil }
        }

        let (maximumFrameBytes, didOverflow) = AudioArtworkLimits.maximumArtworkBytes
            .addingReportingOverflow(AudioArtworkLimits.maximumArtworkMetadataBytes)
        guard !didOverflow else { return nil }
        return readFrames(
            from: &reader,
            tagEnd: tagEnd,
            majorVersion: majorVersion,
            tagFlags: tagFlags,
            maximumFrameBytes: maximumFrameBytes
        )
    }

    private static func readFrames(
        from reader: inout BoundedFileReader,
        tagEnd: UInt64,
        majorVersion: UInt8,
        tagFlags: UInt8,
        maximumFrameBytes: Int
    ) -> Data? {
        let frameHeaderSize = majorVersion == 2 ? 6 : 10
        while reader.offset <= tagEnd, tagEnd - reader.offset >= UInt64(frameHeaderSize) {
            guard !Task.isCancelled,
                  let frameHeader = reader.read(count: frameHeaderSize) else { return nil }
            if frameHeader.allSatisfy({ $0 == 0 }) { break }
            let frameIDLength = majorVersion == 2 ? 3 : 4
            guard let frameID = String(bytes: frameHeader[0..<frameIDLength], encoding: .utf8),
                  let frameSize = frameSize(in: frameHeader, majorVersion: majorVersion),
                  frameSize <= tagEnd - reader.offset else { return nil }
            let isPictureFrame = (majorVersion == 2 && frameID == "PIC")
                || (majorVersion >= 3 && frameID == "APIC")
            guard isPictureFrame else {
                guard reader.skip(frameSize) else { return nil }
                continue
            }
            guard frameSize <= UInt64(maximumFrameBytes),
                  let frameSize = Int(exactly: frameSize),
                  let rawPayload = AudioArtworkFormatSupport.readData(
                      from: &reader,
                      count: frameSize,
                      maximumBytes: UInt64(maximumFrameBytes),
                      maximumReadChunkBytes: AudioArtworkLimits.maximumReadChunkBytes
                  ) else {
                guard reader.skip(frameSize) else { return nil }
                continue
            }
            let frameFlags = majorVersion >= 3
                ? AudioArtworkFormatSupport.bigEndianUInt16(frameHeader, at: 8) ?? 0
                : 0
            let needsUnsynchronization = tagFlags & 0x80 != 0
                || (majorVersion == 4 && frameFlags & 0x0002 != 0)
            let payload = needsUnsynchronization ? deUnsynchronize(rawPayload) : rawPayload
            if let artwork = imageData(in: payload, pictureFrameID: frameID),
               AudioArtworkImageSupport.isValidArtworkData(artwork) {
                return artwork
            }
        }
        return nil
    }

    private static func frameSize(in header: Data, majorVersion: UInt8) -> UInt64? {
        if majorVersion == 2 {
            guard let size = AudioArtworkFormatSupport.bigEndianUInt24(header, at: 3) else { return nil }
            return UInt64(size)
        }
        if majorVersion == 3 {
            guard let size = AudioArtworkFormatSupport.bigEndianUInt32(header, at: 4) else { return nil }
            return UInt64(size)
        }
        guard let size = AudioArtworkFormatSupport.synchsafeUInt32(header, at: 4) else { return nil }
        return UInt64(size)
    }

    private static func skipExtendedHeader(
        from reader: inout BoundedFileReader,
        majorVersion: UInt8,
        end: UInt64
    ) -> Bool {
        guard reader.offset <= end,
              end - reader.offset >= 4,
              let sizeData = reader.read(count: 4) else { return false }
        let size: UInt64
        if majorVersion == 4 {
            guard let value = AudioArtworkFormatSupport.synchsafeUInt32(sizeData, at: 0),
                  value >= 4 else { return false }
            size = UInt64(value - 4)
        } else {
            guard let value = AudioArtworkFormatSupport.bigEndianUInt32(sizeData, at: 0) else { return false }
            size = UInt64(value)
        }
        guard reader.offset <= end, size <= end - reader.offset else { return false }
        return reader.skip(size)
    }

    private static func imageData(in payload: Data, pictureFrameID: String) -> Data? {
        guard let encoding = payload.first else { return nil }
        var cursor = 1

        if pictureFrameID == "PIC" {
            guard cursor + 4 <= payload.count else { return nil }
            cursor += 3
        } else {
            guard let mimeEnd = payload[cursor...].firstIndex(of: 0) else { return nil }
            cursor = mimeEnd + 1
        }

        guard cursor < payload.count else { return nil }
        cursor += 1
        guard let descriptionEnd = descriptionEnd(in: payload, from: cursor, encoding: encoding),
              descriptionEnd < payload.count else { return nil }
        return Data(payload[descriptionEnd...])
    }

    private static func descriptionEnd(in payload: Data, from start: Int, encoding: UInt8) -> Int? {
        if encoding == 1 || encoding == 2 {
            var index = start
            while index + 1 < payload.count {
                if payload[index] == 0, payload[index + 1] == 0 { return index + 2 }
                index += 2
            }
            return nil
        }
        guard let terminator = payload[start...].firstIndex(of: 0) else { return nil }
        return terminator + 1
    }

    private static func deUnsynchronize(_ payload: Data) -> Data {
        var result = Data()
        result.reserveCapacity(payload.count)
        var previousWasFF = false
        for (index, byte) in payload.enumerated() {
            if index & 0xFFFF == 0, Task.isCancelled { return Data() }
            if previousWasFF, byte == 0 {
                previousWasFF = false
                continue
            }
            result.append(byte)
            previousWasFF = byte == 0xFF
        }
        return result
    }
}
