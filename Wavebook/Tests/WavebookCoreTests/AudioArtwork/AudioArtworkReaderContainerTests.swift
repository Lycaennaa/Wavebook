import Foundation
@testable import WavebookCore
import XCTest

extension AudioArtworkReaderTests {
    func testFindsEmbeddedWAVID3Artwork() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.wav")
        try wavFile(artwork: validPNG).write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }

    func testFindsEmbeddedAIFFID3Artwork() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.aiff")
        try aiffFile(artwork: validPNG).write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }

    func testFindsEmbeddedCAFArtwork() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.caf")
        try cafFile(artwork: validPNG).write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }

    func testAACExtensionDoesNotSkipLeadingID3Artwork() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.aac")
        try id3File(artwork: validPNG).write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }

    func testMP4ExtensionDoesNotSkipLeadingID3Artwork() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.mp4")
        try id3File(artwork: validPNG).write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }

    func testMP3ExtensionUsesRIFFSignatureForWAVArtwork() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.mp3")
        try wavFile(artwork: validPNG).write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }

    func testUnsupportedRIFFFormDoesNotUseWAVParser() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.wav")
        var file = Data("RIFF".utf8)
        file.append(contentsOf: littleEndianBytes(4))
        file.append(Data("AVI ".utf8))
        try file.write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertNil(artwork)
    }

    func testTruncatedContainerArtworkFailsSafely() async throws {
        let root = try makeRoot()
        let files: [(String, Data)] = [
            ("truncated.wav", truncatedWAV()),
            ("truncated.aiff", truncatedAIFF()),
            ("truncated.caf", truncatedCAF())
        ]

        for (name, data) in files {
            let audio = root.appending(path: name)
            try data.write(to: audio)
            let artwork = await AudioArtworkReader().artworkData(for: audio)
            XCTAssertNil(artwork, name)
        }
    }

    func testCAFArtworkRespectsPixelAreaLimit() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "large.caf")
        try cafFile(artwork: pngWithDimensions(width: 6_000, height: 6_000)).write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertNil(artwork)
    }

    func testFindsEmbeddedAIFCArtwork() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.aifc")
        try aiffFile(artwork: validPNG, formType: "AIFC").write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }

    func testCAFArtworkRespectsEncodedSizeLimit() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "oversized.caf")
        let payloadSize = 32 * 1_024 * 1_024 + 1
        try makeSparseFile(at: audio, size: 8 + 12 + payloadSize)

        var header = Data("caff".utf8)
        header.append(contentsOf: [0, 1, 0, 0])
        header.append(Data("covr".utf8))
        header.append(contentsOf: bigEndianBytes64(UInt64(payloadSize)))
        let handle = try FileHandle(forWritingTo: audio)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertNil(artwork)
    }
}
