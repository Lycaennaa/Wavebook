import Foundation

enum AudioFLACArtworkReader {
    static func artworkData(from reader: inout BoundedFileReader) -> Data? {
        guard let signature = reader.read(count: 4),
              AudioArtworkFormatSupport.dataStarts(signature, with: [0x66, 0x4C, 0x61, 0x43]) else { return nil }
        var isLastBlock = false
        while !isLastBlock {
            guard !Task.isCancelled, let blockHeader = reader.read(count: 4) else { return nil }
            isLastBlock = blockHeader[0] & 0x80 != 0
            let blockType = blockHeader[0] & 0x7F
            guard let blockLength = AudioArtworkFormatSupport.bigEndianUInt24(blockHeader, at: 1) else { return nil }
            let blockEnd = reader.offset + UInt64(blockLength)
            guard blockEnd <= reader.limit else { return nil }

            if blockType == 6 {
                if let artwork = pictureData(from: &reader, end: blockEnd) {
                    return artwork
                }
                guard reader.seek(to: blockEnd) else { return nil }
            } else {
                guard reader.skip(UInt64(blockLength)) else { return nil }
            }
        }
        return nil
    }

    private static let maximumPictureBlockBytes: UInt64 = (1 << 24) - 1

    private struct PictureHeader {
        let dataLength: Int
    }

    private static func pictureData(from reader: inout BoundedFileReader, end: UInt64) -> Data? {
        let count = end - reader.offset
        guard count <= maximumPictureBlockBytes,
              count <= UInt64(Int.max),
              let picture = AudioArtworkFormatSupport.readData(
                  from: &reader,
                  count: Int(count),
                  maximumBytes: maximumPictureBlockBytes,
                  maximumReadChunkBytes: AudioArtworkLimits.maximumReadChunkBytes
              ) else { return nil }
        return artworkData(inPicture: picture)
    }

    static func artworkData(inPicture picture: Data) -> Data? {
        var cursor = 0
        guard let header = pictureHeader(from: picture, cursor: &cursor) else { return nil }
        let end = cursor + header.dataLength
        guard end <= picture.count else { return nil }
        let artwork = Data(picture[cursor..<end])
        return AudioArtworkImageSupport.isValidArtworkData(artwork) ? artwork : nil
    }

    private static func pictureHeader(from picture: Data, cursor: inout Int) -> PictureHeader? {
        guard skipPictureUInt32(from: picture, cursor: &cursor),
              let mimeLength = AudioArtworkFormatSupport.readBigEndianUInt32(picture, cursor: &cursor),
              mimeLength <= UInt32(picture.count - cursor) else { return nil }
        cursor += Int(mimeLength)
        guard let descriptionLength = AudioArtworkFormatSupport.readBigEndianUInt32(picture, cursor: &cursor),
              descriptionLength <= UInt32(picture.count - cursor) else { return nil }
        cursor += Int(descriptionLength)
        guard skipPictureUInt32(from: picture, cursor: &cursor),
              skipPictureUInt32(from: picture, cursor: &cursor),
              skipPictureUInt32(from: picture, cursor: &cursor),
              skipPictureUInt32(from: picture, cursor: &cursor),
              let dataLength = AudioArtworkFormatSupport.readBigEndianUInt32(picture, cursor: &cursor),
              dataLength > 0,
              dataLength <= UInt32(AudioArtworkLimits.maximumArtworkBytes),
              dataLength <= UInt32(picture.count - cursor) else { return nil }
        return PictureHeader(dataLength: Int(dataLength))
    }

    private static func skipPictureUInt32(from picture: Data, cursor: inout Int) -> Bool {
        AudioArtworkFormatSupport.readBigEndianUInt32(picture, cursor: &cursor) != nil
    }
}
