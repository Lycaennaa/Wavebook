@testable import WavebookCore
import XCTest

final class AudioArtworkReaderTests: XCTestCase {

    var alternateValidPNG: Data {
        guard let data = Data(
             base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0" +
                 "lEQVR4nGP4/x8AAwAB//wl3FEAAAAASUVORK5CYII="
        ) else {
            preconditionFailure("Test fixture must contain valid Base64")
        }
        return data
    }
    var validWebP: Data {
        guard let data = Data(
            base64Encoded: "UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoCAAIAAgA0JaACdLoB+AADsAD+8" +
                "Oj3/yC5YXXI1/8gP+QH/ID/+PIAAAA="
        ) else {
            preconditionFailure("Test fixture must contain valid Base64")
        }
        return data
    }

    func wavFile(artwork: Data) -> Data {
        var body = Data("WAVE".utf8)
        body.append(riffChunk("id3 ", payload: id3File(artwork: artwork)))

        var file = Data("RIFF".utf8)
        file.append(contentsOf: littleEndianBytes(UInt32(body.count)))
        file.append(body)
        return file
    }

    func aiffFile(artwork: Data, formType: String = "AIFF") -> Data {
        var body = Data(formType.utf8)
        body.append(aiffChunk("ID3 ", payload: id3File(artwork: artwork)))

        var file = Data("FORM".utf8)
        file.append(contentsOf: bigEndianBytes(UInt32(body.count)))
        file.append(body)
        return file
    }

    func cafFile(artwork: Data) -> Data {
        var file = Data("caff".utf8)
        file.append(contentsOf: [0, 1, 0, 0])
        var payload = Data(repeating: 0, count: 16)
        payload.append(artwork)
        file.append(Data("uuid".utf8))
        file.append(contentsOf: bigEndianBytes64(UInt64(payload.count)))
        file.append(payload)
        return file
    }

    func riffChunk(_ type: String, payload: Data) -> Data {
        var chunk = Data(type.utf8)
        chunk.append(contentsOf: littleEndianBytes(UInt32(payload.count)))
        chunk.append(payload)
        if payload.count % 2 == 1 { chunk.append(0) }
        return chunk
    }

    func aiffChunk(_ type: String, payload: Data) -> Data {
        var chunk = Data(type.utf8)
        chunk.append(contentsOf: bigEndianBytes(UInt32(payload.count)))
        chunk.append(payload)
        if payload.count % 2 == 1 { chunk.append(0) }
        return chunk
    }

    func truncatedWAV() -> Data {
        var file = Data("RIFF".utf8)
        file.append(contentsOf: littleEndianBytes(32))
        file.append(Data("WAVEid3 ".utf8))
        file.append(contentsOf: littleEndianBytes(16))
        return file
    }

    func truncatedAIFF() -> Data {
        var file = Data("FORM".utf8)
        file.append(contentsOf: bigEndianBytes(32))
        file.append(Data("AIFFID3 ".utf8))
        file.append(contentsOf: bigEndianBytes(16))
        return file
    }

    func truncatedCAF() -> Data {
        var file = Data("caff".utf8)
        file.append(contentsOf: [0, 1, 0, 0])
        file.append(Data("uuid".utf8))
        file.append(contentsOf: bigEndianBytes64(UInt64(16)))
        return file
    }

    func pictureBlock(
        artwork: Data,
        width: UInt32 = 1,
        height: UInt32 = 1,
        mimeType: String = "image/png",
        dataLength: UInt32? = nil
    ) -> Data {
        var picture = Data()
        picture.append(contentsOf: bigEndianBytes(3))
        let mime = Data(mimeType.utf8)
        picture.append(contentsOf: bigEndianBytes(UInt32(mime.count)))
        picture.append(mime)
        picture.append(contentsOf: bigEndianBytes(0))
        picture.append(contentsOf: bigEndianBytes(width))
        picture.append(contentsOf: bigEndianBytes(height))
        picture.append(contentsOf: bigEndianBytes(32))
        picture.append(contentsOf: bigEndianBytes(0))
        picture.append(contentsOf: bigEndianBytes(dataLength ?? UInt32(artwork.count)))
        if dataLength == nil { picture.append(artwork) }
        return picture
    }

    func flacFile(
        artwork: Data,
        width: UInt32 = 1,
        height: UInt32 = 1,
        mimeType: String = "image/png",
        dataLength: UInt32? = nil
    ) -> Data {
        let picture = pictureBlock(
            artwork: artwork,
            width: width,
            height: height,
            mimeType: mimeType,
            dataLength: dataLength
        )

        var file = Data("fLaC".utf8)
        file.append(contentsOf: [0x86])
        file.append(contentsOf: [
            UInt8(truncatingIfNeeded: picture.count >> 16),
            UInt8(truncatingIfNeeded: picture.count >> 8),
            UInt8(truncatingIfNeeded: picture.count)
        ])
        file.append(picture)
        return file
    }

    func id3File(artwork: Data) -> Data {
        var payload = Data([3])
        payload.append(contentsOf: Data("image/png".utf8))
        payload.append(0)
        payload.append(3)
        payload.append(0)
        payload.append(artwork)

        var frame = Data("APIC".utf8)
        frame.append(contentsOf: bigEndianBytes(UInt32(payload.count)))
        frame.append(contentsOf: [0, 0])
        frame.append(payload)

        var file = Data("ID3".utf8)
        file.append(contentsOf: [3, 0, 0])
        file.append(contentsOf: synchsafeBytes(UInt32(frame.count)))
        file.append(frame)
        return file
    }

    func opusFile(artwork: Data) -> Data {
        opusFile(comment: Data("COVERART=\(artwork.base64EncodedString())".utf8))
    }

    func opusPictureFile(
        artwork: Data,
        width: UInt32,
        height: UInt32,
        mimeType: String
    ) -> Data {
        let picture = pictureBlock(
            artwork: artwork,
            width: width,
            height: height,
            mimeType: mimeType
        )
        return opusFile(comment: Data(
            "METADATA_BLOCK_PICTURE=\(picture.base64EncodedString())".utf8
        ))
    }

    func opusFile(comment: Data) -> Data {
        var tags = Data("OpusTags".utf8)
        tags.append(contentsOf: littleEndianBytes(0))
        tags.append(contentsOf: littleEndianBytes(1))
        tags.append(contentsOf: littleEndianBytes(UInt32(comment.count)))
        tags.append(comment)

        var head = Data("OpusHead".utf8)
        head.append(Data(repeating: 0, count: 11))
        return oggPage(packets: [head, tags])
    }

    func oggPage(packets: [Data]) -> Data {
        var lacing: [UInt8] = []
        var payload = Data()
        for packet in packets {
            var offset = 0
            while packet.count - offset >= 255 {
                lacing.append(255)
                payload.append(packet[offset..<(offset + 255)])
                offset += 255
            }
            lacing.append(UInt8(packet.count - offset))
            payload.append(packet[offset...])
        }

        var page = Data("OggS".utf8)
        page.append(contentsOf: [0, 0])
        page.append(Data(repeating: 0, count: 8))
        page.append(contentsOf: littleEndianBytes(1))
        page.append(contentsOf: littleEndianBytes(0))
        page.append(contentsOf: littleEndianBytes(0))
        page.append(UInt8(lacing.count))
        page.append(contentsOf: lacing)
        page.append(payload)
        return page
    }

    func m4aFile(artwork: Data) -> Data {
        var dataPayload = Data(repeating: 0, count: 8)
        dataPayload.append(artwork)
        let data = mp4Atom("data", payload: dataPayload)
        let covr = mp4Atom("covr", payload: data)
        let ilst = mp4Atom("ilst", payload: covr)
        var metaPayload = Data(repeating: 0, count: 4)
        metaPayload.append(ilst)
        let meta = mp4Atom("meta", payload: metaPayload)
        let udta = mp4Atom("udta", payload: meta)
        let moov = mp4Atom("moov", payload: udta)
        var file = mp4Atom("ftyp", payload: Data())
        file.append(moov)
        return file
    }

    func mp4Atom(_ type: String, payload: Data) -> Data {
        var atom = Data()
        atom.append(contentsOf: bigEndianBytes(UInt32(payload.count + 8)))
        atom.append(contentsOf: type.utf8)
        atom.append(payload)
        return atom
    }

    func synchsafeBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 21) & 0x7F,
            UInt8(truncatingIfNeeded: value >> 14) & 0x7F,
            UInt8(truncatingIfNeeded: value >> 7) & 0x7F,
            UInt8(truncatingIfNeeded: value) & 0x7F
        ]
    }

    func pngWithDimensions(width: UInt32, height: UInt32) -> Data {
        var data = validPNG
        data.replaceSubrange(16..<20, with: bigEndianBytes(width))
        data.replaceSubrange(20..<24, with: bigEndianBytes(height))
        data.replaceSubrange(29..<33, with: bigEndianBytes(crc32(Data(data[12..<29]))))
        return data
    }

    func littleEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24)
        ]
    }

    func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
    }

    func bigEndianBytes64(_ value: UInt64) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 56),
            UInt8(truncatingIfNeeded: value >> 48),
            UInt8(truncatingIfNeeded: value >> 40),
            UInt8(truncatingIfNeeded: value >> 32),
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
    }

    func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    var validPNG: Data {
        guard let data = Data(
             base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0" +
                 "lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ) else {
            preconditionFailure("Test fixture must contain valid Base64")
        }
        return data
    }

    func makeSparseFile(at url: URL, size: Int) throws {
        try Data([0]).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(size - 1))
        try handle.write(contentsOf: Data([0]))
    }

    func makeRoot() throws -> URL {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".test-tmp")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}

func isCurrentThreadMain() -> Bool {
    Thread.isMainThread
}
