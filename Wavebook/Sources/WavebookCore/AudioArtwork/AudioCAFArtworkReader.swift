import Foundation

enum AudioCAFArtworkReader {
    static func artworkData(
        from reader: inout BoundedFileReader,
        maximumArtworkBytes: UInt64,
        maximumID3Bytes: UInt64,
        maximumReadChunkBytes: Int
    ) -> Data? {
        guard let header = reader.read(count: 8),
              AudioArtworkFormatSupport.dataMatches(header, at: 0, bytes: [0x63, 0x61, 0x66, 0x66]),
              AudioArtworkFormatSupport.bigEndianUInt16(header, at: 4) == 1 else { return nil }

        while reader.offset < reader.limit {
            guard !Task.isCancelled,
                  reader.limit - reader.offset >= 12,
                  let chunkHeader = reader.read(count: 12),
                  let chunkSize = AudioArtworkFormatSupport.bigEndianUInt64(chunkHeader, at: 4),
                  chunkSize <= reader.limit - reader.offset else { return nil }
            let chunkEnd = reader.offset + chunkSize
            let chunkType = Data(chunkHeader[0..<4])

            if isID3Chunk(chunkType), chunkSize <= maximumID3Bytes {
                if let artwork = readID3Chunk(from: &reader, end: chunkEnd, maximumBytes: maximumID3Bytes) {
                    return artwork
                }
            } else if isUUIDChunk(chunkType),
                      let artwork = readUUIDArtwork(
                          from: &reader,
                          end: chunkEnd,
                          maximumArtworkBytes: maximumArtworkBytes,
                          maximumID3Bytes: maximumID3Bytes,
                          maximumReadChunkBytes: maximumReadChunkBytes
                      ) {
                return artwork
            } else if isDirectArtworkChunk(chunkType),
                      let artwork = readImageData(
                          from: &reader,
                          end: chunkEnd,
                          maximumArtworkBytes: maximumArtworkBytes,
                          maximumReadChunkBytes: maximumReadChunkBytes
                      ) {
                return artwork
            }

            guard reader.seek(to: chunkEnd) else { return nil }
        }
        return nil
    }

    private static func readUUIDArtwork(
        from reader: inout BoundedFileReader,
        end: UInt64,
        maximumArtworkBytes: UInt64,
        maximumID3Bytes: UInt64,
        maximumReadChunkBytes: Int
    ) -> Data? {
        let start = reader.offset
        if let artwork = readID3Chunk(from: &reader, end: end, maximumBytes: maximumID3Bytes) {
            return artwork
        }
        guard reader.seek(to: start) else { return nil }

        if end - start >= 16, reader.skip(16) {
            if let artwork = readID3Chunk(from: &reader, end: end, maximumBytes: maximumID3Bytes) {
                return artwork
            }
            guard reader.seek(to: start + 16) else { return nil }
            if let artwork = readImageData(
                from: &reader,
                end: end,
                maximumArtworkBytes: maximumArtworkBytes,
                maximumReadChunkBytes: maximumReadChunkBytes
            ) {
                return artwork
            }
        }

        guard reader.seek(to: start) else { return nil }
        return readImageData(
            from: &reader,
            end: end,
            maximumArtworkBytes: maximumArtworkBytes,
            maximumReadChunkBytes: maximumReadChunkBytes
        )
    }

    private static func readID3Chunk(
        from reader: inout BoundedFileReader,
        end: UInt64,
        maximumBytes: UInt64
    ) -> Data? {
        guard reader.offset <= end, end - reader.offset <= maximumBytes else { return nil }
        return AudioID3ArtworkReader.artworkData(from: &reader, end: end)
    }

    private static func readImageData(
        from reader: inout BoundedFileReader,
        end: UInt64,
        maximumArtworkBytes: UInt64,
        maximumReadChunkBytes: Int
    ) -> Data? {
        guard reader.offset <= end else { return nil }
        let length = end - reader.offset
        guard length > 0,
              length <= maximumArtworkBytes,
              let count = Int(exactly: length),
              let artwork = AudioArtworkFormatSupport.readData(
                  from: &reader,
                  count: count,
                  maximumBytes: maximumArtworkBytes,
                  maximumReadChunkBytes: maximumReadChunkBytes
              ),
              AudioArtworkImageSupport.isValidArtworkData(artwork) else { return nil }
        return artwork
    }

    private static func isID3Chunk(_ data: Data) -> Bool {
        AudioArtworkFormatSupport.isFourCC(data, [0x69, 0x64, 0x33, 0x20]) ||
            AudioArtworkFormatSupport.isFourCC(data, [0x49, 0x44, 0x33, 0x20])
    }

    private static func isUUIDChunk(_ data: Data) -> Bool {
        AudioArtworkFormatSupport.isFourCC(data, [0x75, 0x75, 0x69, 0x64])
    }

    private static func isDirectArtworkChunk(_ data: Data) -> Bool {
        AudioArtworkFormatSupport.isFourCC(data, [0x63, 0x6F, 0x76, 0x72]) ||
            AudioArtworkFormatSupport.isFourCC(data, [0x70, 0x69, 0x63, 0x74]) ||
            AudioArtworkFormatSupport.isFourCC(data, [0x70, 0x69, 0x63, 0x20]) ||
            AudioArtworkFormatSupport.isFourCC(data, [0x61, 0x72, 0x74, 0x77]) ||
            AudioArtworkFormatSupport.isFourCC(data, [0x61, 0x72, 0x74, 0x20])
    }
}
