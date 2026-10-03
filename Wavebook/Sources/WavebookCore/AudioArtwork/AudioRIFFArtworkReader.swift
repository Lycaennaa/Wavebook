import Foundation

enum AudioRIFFArtworkReader {
    static func artworkData(
        from reader: inout BoundedFileReader,
        maximumArtworkBytes: UInt64,
        maximumID3Bytes: UInt64,
        maximumReadChunkBytes: Int
    ) -> Data? {
        guard let header = reader.read(count: 12),
              AudioArtworkFormatSupport.dataMatches(header, at: 0, bytes: [0x52, 0x49, 0x46, 0x46]),
              AudioArtworkFormatSupport.dataMatches(header, at: 8, bytes: [0x57, 0x41, 0x56, 0x45]),
              let declaredSize = AudioArtworkFormatSupport.littleEndianUInt32(header, at: 4),
              reader.limit >= 8,
              UInt64(declaredSize) >= 4,
              UInt64(declaredSize) <= reader.limit - 8 else { return nil }

        let end = UInt64(declaredSize) + 8
        while reader.offset < end {
            guard !Task.isCancelled,
                  end - reader.offset >= 8,
                  let chunkHeader = reader.read(count: 8),
                  let chunkSize = AudioArtworkFormatSupport.littleEndianUInt32(chunkHeader, at: 4),
                  UInt64(chunkSize) <= end - reader.offset else { return nil }
            let chunkEnd = reader.offset + UInt64(chunkSize)
            let chunkType = Data(chunkHeader[0..<4])

            if isID3Chunk(chunkType), UInt64(chunkSize) <= maximumID3Bytes {
                if let artwork = readID3Chunk(from: &reader, end: chunkEnd, maximumBytes: maximumID3Bytes) {
                    return artwork
                }
            } else if isListChunk(chunkType),
                      let artwork = readListArtwork(
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

            guard reader.finishPaddedChunk(
                chunkEnd: chunkEnd,
                containerEnd: end,
                chunkSize: UInt64(chunkSize)
            ) else { return nil }
        }
        return nil
    }

    private static func readListArtwork(
        from reader: inout BoundedFileReader,
        end: UInt64,
        maximumArtworkBytes: UInt64,
        maximumID3Bytes: UInt64,
        maximumReadChunkBytes: Int
    ) -> Data? {
        guard reader.offset <= end,
              end - reader.offset >= 4,
              let listType = reader.read(count: 4) else { return nil }
        let nestedStart = reader.offset
        if isID3Chunk(listType),
           let artwork = readID3Chunk(from: &reader, end: end, maximumBytes: maximumID3Bytes) {
            return artwork
        }
        if isDirectArtworkChunk(listType),
           let artwork = readImageData(
               from: &reader,
               end: end,
               maximumArtworkBytes: maximumArtworkBytes,
               maximumReadChunkBytes: maximumReadChunkBytes
           ) {
            return artwork
        }
        guard reader.seek(to: nestedStart) else { return nil }

        while reader.offset < end {
            guard !Task.isCancelled,
                  end - reader.offset >= 8,
                  let chunkHeader = reader.read(count: 8),
                  let chunkSize = AudioArtworkFormatSupport.littleEndianUInt32(chunkHeader, at: 4),
                  UInt64(chunkSize) <= end - reader.offset else { return nil }
            let chunkEnd = reader.offset + UInt64(chunkSize)
            let chunkType = Data(chunkHeader[0..<4])
            if isID3Chunk(chunkType), UInt64(chunkSize) <= maximumID3Bytes {
                if let artwork = readID3Chunk(from: &reader, end: chunkEnd, maximumBytes: maximumID3Bytes) {
                    return artwork
                }
            } else if isDirectArtworkChunk(chunkType),
                      let artwork = readImageData(
                          from: &reader,
                          end: chunkEnd,
                          maximumArtworkBytes: maximumArtworkBytes,
                          maximumReadChunkBytes: maximumReadChunkBytes
                      ) {
                return artwork
            }
            guard reader.finishPaddedChunk(
                chunkEnd: chunkEnd,
                containerEnd: end,
                chunkSize: UInt64(chunkSize)
            ) else { return nil }
        }
        return nil
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

    private static func isListChunk(_ data: Data) -> Bool {
        AudioArtworkFormatSupport.isFourCC(data, [0x6C, 0x69, 0x73, 0x74])
    }

    private static func isDirectArtworkChunk(_ data: Data) -> Bool {
        AudioArtworkFormatSupport.isFourCC(data, [0x63, 0x6F, 0x76, 0x72]) ||
            AudioArtworkFormatSupport.isFourCC(data, [0x70, 0x69, 0x63, 0x74]) ||
            AudioArtworkFormatSupport.isFourCC(data, [0x70, 0x69, 0x63, 0x20]) ||
            AudioArtworkFormatSupport.isFourCC(data, [0x61, 0x72, 0x74, 0x77]) ||
            AudioArtworkFormatSupport.isFourCC(data, [0x61, 0x72, 0x74, 0x20])
    }
}
