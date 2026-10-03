import Foundation
@testable import WavebookCore
import XCTest

extension AudioArtworkReaderTests {
    func testFindsSameDirectoryCoverArtByPriorityName() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "Song.flac")
        let cover = root.appending(path: "cover.jpg")
        let ignored = root.appending(path: "other.jpg")

        try Data().write(to: audio)
        try validPNG.write(to: cover)
        try Data([9]).write(to: ignored)

        let reader = AudioArtworkReader()
        XCTAssertEqual(reader.sidecarArtworkURL(for: audio), cover)
        let artwork = await reader.artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }
    func testFindsSameDirectoryWebPSidecarForOpus() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.opus")
        let cover = root.appending(path: "cover.webp")
        try Data().write(to: audio)
        try validWebP.write(to: cover)

        let reader = AudioArtworkReader()
        XCTAssertEqual(reader.sidecarArtworkURL(for: audio), cover)
        let artwork = await reader.artworkData(for: audio)
        XCTAssertEqual(artwork, validWebP)
    }

    func testCorruptFirstSidecarDoesNotHideValidLaterCandidate() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        try Data().write(to: audio)
        try Data([1, 2, 3]).write(to: root.appending(path: "cover.jpg"))
        let folder = root.appending(path: "folder.png")
        try validPNG.write(to: folder)

        let reader = AudioArtworkReader()
        XCTAssertEqual(reader.sidecarArtworkURL(for: audio), folder)
        let artwork = await reader.artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }
    func testOversizedSidecarDoesNotHideValidLaterCandidate() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        let oversized = root.appending(path: "cover.jpg")
        let folder = root.appending(path: "folder.png")
        try Data().write(to: audio)
        try makeSparseFile(at: oversized, size: 32 * 1_024 * 1_024 + 1)
        try validPNG.write(to: folder)

        let reader = AudioArtworkReader()
        XCTAssertEqual(reader.sidecarArtworkURL(for: audio), folder)
        let artwork = await reader.artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }

    func testFindsSidecarInLargeDirectoryWithBoundedCandidateStorage() throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        let cover = root.appending(path: "cover.jpg")
        try Data().write(to: audio)
        for index in 0..<2_000 {
            try Data([0]).write(to: root.appending(path: "unrelated-\(index).jpg"))
        }
        try validPNG.write(to: cover)

        XCTAssertEqual(AudioArtworkReader().sidecarArtworkURL(for: audio), cover)
    }

    func testSidecarArtworkDoesNotSearchNestedDirectories() throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        let nested = root.appending(path: "nested")
        try Data().write(to: audio)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try validPNG.write(to: nested.appending(path: "cover.jpg"))

        XCTAssertNil(AudioArtworkReader().sidecarArtworkURL(for: audio))
    }

    func testSidecarDiscoveryRechecksCandidateContents() throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        let cover = root.appending(path: "cover.jpg")
        let reader = AudioArtworkReader()
        try Data().write(to: audio)
        try Data([1, 2, 3]).write(to: cover)

        XCTAssertNil(reader.sidecarArtworkURL(for: audio))

        try validPNG.write(to: cover)
        XCTAssertEqual(reader.sidecarArtworkURL(for: audio), cover)
    }
    func testSidecarDiscoveryFindsCoverAddedAfterEmptyScan() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.opus")
        let cover = root.appending(path: "cover.webp")
        try Data().write(to: audio)

        let reader = AudioArtworkReader()
        XCTAssertNil(reader.sidecarArtworkURL(for: audio))

        try validWebP.write(to: cover)
        XCTAssertEqual(reader.sidecarArtworkURL(for: audio), cover)
        let artwork = await reader.artworkData(for: audio)
        XCTAssertEqual(artwork, validWebP)
    }

    func testSidecarDiscoveryFindsHigherPrioritySidecar() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        let folder = root.appending(path: "folder.png")
        let cover = root.appending(path: "cover.jpg")
        try Data().write(to: audio)
        try alternateValidPNG.write(to: folder)

        let reader = AudioArtworkReader()
        XCTAssertEqual(reader.sidecarArtworkURL(for: audio), folder)

        try validPNG.write(to: cover)
        XCTAssertEqual(reader.sidecarArtworkURL(for: audio), cover)
        let artwork = await reader.artworkData(for: audio)
        XCTAssertEqual(artwork, validPNG)
    }

    func testArtworkCacheFingerprintChangesForSidecarEdit() throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        let cover = root.appending(path: "cover.jpg")
        try Data().write(to: audio)
        try validPNG.write(to: cover)

        let reader = AudioArtworkReader()
        let before = reader.artworkCacheFingerprint(for: audio)
        try Data([1, 2, 3]).write(to: cover)

        XCTAssertNotEqual(before, reader.artworkCacheFingerprint(for: audio))
    }
    func testArtworkCacheFingerprintChangesForSameSizeSidecarRewriteWithRestoredModificationDate() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        let cover = root.appending(path: "cover.jpg")
        try Data().write(to: audio)
        try validPNG.write(to: cover)

        let reader = AudioArtworkReader()
        let originalValues = try cover.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        )
        let originalDate = try XCTUnwrap(originalValues.contentModificationDate)
        let originalResourceIdentifier = String(describing: originalValues.fileResourceIdentifier)
        let before = reader.artworkCacheFingerprint(for: audio)
        let replacement = alternateValidPNG
        XCTAssertEqual(replacement.count, originalValues.fileSize)

        do {
            let handle = try FileHandle(forWritingTo: cover)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: replacement)
        }
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: cover.path)

        let restoredValues = try cover.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        )
        XCTAssertEqual(restoredValues.fileSize, originalValues.fileSize)
        XCTAssertEqual(restoredValues.contentModificationDate, originalDate)
        XCTAssertEqual(String(describing: restoredValues.fileResourceIdentifier), originalResourceIdentifier)
        XCTAssertEqual(reader.sidecarArtworkURL(for: audio), cover)
        XCTAssertNotEqual(before, reader.artworkCacheFingerprint(for: audio))
        let artwork = await reader.artworkData(for: audio)
        XCTAssertEqual(artwork, replacement)
    }
    func testArtworkCacheFingerprintChangesForSameSizeEmbeddedRewriteWithRestoredModificationDate() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "song.flac")
        let originalFile = flacFile(artwork: validPNG)
        try originalFile.write(to: audio)

        let reader = AudioArtworkReader()
        let originalValues = try audio.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        )
        let originalDate = try XCTUnwrap(originalValues.contentModificationDate)
        let originalResourceIdentifier = String(describing: originalValues.fileResourceIdentifier)
        let before = reader.artworkCacheFingerprint(for: audio)
        let replacement = alternateValidPNG
        XCTAssertEqual(replacement.count, validPNG.count)
        let artworkOffset = try XCTUnwrap(originalFile.range(of: validPNG)?.lowerBound)

        do {
            let handle = try FileHandle(forWritingTo: audio)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(artworkOffset))
            try handle.write(contentsOf: replacement)
        }
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: audio.path)

        let restoredValues = try audio.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        )
        XCTAssertEqual(restoredValues.fileSize, originalValues.fileSize)
        XCTAssertEqual(restoredValues.contentModificationDate, originalDate)
        XCTAssertEqual(String(describing: restoredValues.fileResourceIdentifier), originalResourceIdentifier)
        XCTAssertNotEqual(before, reader.artworkCacheFingerprint(for: audio))
        let artwork = await reader.artworkData(for: audio)
        XCTAssertEqual(artwork, replacement)
    }

    func testIgnoresNonImageSidecars() throws {
        let root = try makeRoot()
        let audio = root.appending(path: "Song.flac")

        try Data().write(to: audio)
        try Data([1]).write(to: root.appending(path: "cover.txt"))

        XCTAssertNil(AudioArtworkReader().sidecarArtworkURL(for: audio))
    }

}
