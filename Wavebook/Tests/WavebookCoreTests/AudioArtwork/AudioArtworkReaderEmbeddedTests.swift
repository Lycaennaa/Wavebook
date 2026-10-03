import Foundation
@testable import WavebookCore
import XCTest

extension AudioArtworkReaderTests {
    func testRejectsArtworkOverPixelAreaLimit() throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        let cover = root.appending(path: "cover.png")
        try Data().write(to: audio)
        try pngWithDimensions(width: 6_000, height: 6_000).write(to: cover)

        XCTAssertNil(AudioArtworkReader().sidecarArtworkURL(for: audio))
    }
    func testAllowsArtworkWithinExpandedPixelAreaLimit() {
        XCTAssertTrue(AudioArtworkImageSupport.isPixelAreaWithinBounds(5_000, 5_000))
    }

    func testFindsEmbeddedFLACPicture() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        try flacFile(artwork: validPNG).write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }
    func testFindsEmbeddedFLACPictureWithMissingMetadataDimensions() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        try flacFile(artwork: validPNG, width: 0, height: 0, mimeType: "").write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }

    func testFindsEmbeddedID3Artwork() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.mp3")
        try id3File(artwork: validPNG).write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }

    func testFindsEmbeddedM4AArtwork() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.m4a")
        try m4aFile(artwork: validPNG).write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }

    func testFindsEmbeddedOpusArtwork() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.opus")
        try opusFile(artwork: validPNG).write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }
    func testFindsEmbeddedOpusPictureWithMissingMetadataDimensions() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.opus")
        try opusPictureFile(artwork: validPNG, width: 0, height: 0, mimeType: "").write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }

    func testRejectsEmbeddedArtworkOverEncodedSizeLimit() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        try flacFile(artwork: validPNG, dataLength: UInt32(32 * 1_024 * 1_024 + 1)).write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertNil(artwork)
    }

    func testRejectsEmbeddedArtworkOverPixelAreaLimit() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        let oversizedArtwork = pngWithDimensions(width: 6_000, height: 6_000)
        try flacFile(artwork: oversizedArtwork, width: 0, height: 0).write(to: audio)

        let artwork = await AudioArtworkReader().artworkData(for: audio)
        XCTAssertNil(artwork)
    }

    func testRejectsArtworkWithOverflowingPixelArea() throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        let cover = root.appending(path: "cover.png")
        try Data().write(to: audio)
        try pngWithDimensions(width: .max, height: .max).write(to: cover)

        XCTAssertNil(AudioArtworkReader().sidecarArtworkURL(for: audio))
    }

    func testCancelledArtworkReadDoesNotDeliverData() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        try flacFile(artwork: validPNG).write(to: audio)

        let task = Task { () -> Data? in
            await Task.yield()
            return await AudioArtworkReader().artworkData(for: audio)
        }
        task.cancel()

        let artwork = await task.value
        XCTAssertNil(artwork)
    }

    func testArtworkDecodeCanRunOffMainActor() async {
        let data = validPNG
        let ranOnMainThread = await Task.detached(priority: .utility) {
            _ = AudioArtworkReader.decodedArtworkImage(data, maximumPixelSize: 256)
            return isCurrentThreadMain()
        }.value

        XCTAssertFalse(ranOnMainThread)
    }
    func testImageIODecodesWebPArtwork() {
        XCTAssertNotNil(AudioArtworkReader.decodedArtworkImage(validWebP, maximumPixelSize: 256))
    }
}
