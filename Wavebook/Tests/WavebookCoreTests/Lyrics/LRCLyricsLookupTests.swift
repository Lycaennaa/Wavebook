import Foundation
@testable import WavebookCore
import XCTest

extension LRCLyricsTests {
    func testSidecarWinsOverIndexedLibraryMatch() async throws {
        let root = try makeRoot()
        let music = root.appending(path: "Music", directoryHint: .isDirectory)
        let lyricsFolder = root.appending(path: "Lyrics/Album", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lyricsFolder, withIntermediateDirectories: true)
        let audio = music.appending(path: "Song.flac")
        let indexedLyrics = lyricsFolder.appending(path: "song.LRC")
        try Data().write(to: audio)
        try "[00:00]Sidecar".write(to: music.appending(path: "Song.lrc"), atomically: true, encoding: .utf8)
        try "[00:00]Library".write(to: indexedLyrics, atomically: true, encoding: .utf8)
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
         _ = try database.save(
             track: Track(
                 path: audio.path,
                 title: "Song",
                 artistDisplay: "",
                 albumTitle: "",
                 genreDisplay: "",
                 duration: 0,
                 format: "flac"
             ),
             rootID: rootID
         )
        try database.registerLyricFile(indexedLyrics, forTrackPath: audio.path)

        let lyrics = try await LRCLyricsLoader().lyrics(for: audio, database: database)

        XCTAssertEqual(lyrics?.lines.first?.text, "Sidecar")
    }

    func testSidecarAvailabilityDoesNotRequireIndex() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "Song.flac")
        let sidecar = root.appending(path: "Song.lrc")
        try Data().write(to: audio)
        try "[00:00]Sidecar".write(to: sidecar, atomically: true, encoding: .utf8)

        let lyricURL = try await LRCLyricsLoader().lyricFileURL(for: audio, database: nil)
        XCTAssertEqual(lyricURL, sidecar)
    }

    func testFindsIndexedSameNamedLRCInLibraryRoot() async throws {
        let root = try makeRoot()
        let music = root.appending(path: "Music", directoryHint: .isDirectory)
        let lyricsFolder = root.appending(path: "Other/Lyrics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lyricsFolder, withIntermediateDirectories: true)
        let audio = music.appending(path: "My Song.mp3")
        let indexedLyrics = lyricsFolder.appending(path: "my song.lrc")
        try Data().write(to: audio)
        try "[00:00]Found remotely".write(to: indexedLyrics, atomically: true, encoding: .utf8)
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
         _ = try database.save(
             track: Track(
                 path: audio.path,
                 title: "My Song",
                 artistDisplay: "",
                 albumTitle: "",
                 genreDisplay: "",
                 duration: 0,
                 format: "mp3"
             ),
             rootID: rootID
         )
        try database.registerLyricFile(indexedLyrics, forTrackPath: audio.path)

        let lyrics = try await LRCLyricsLoader().lyrics(for: audio, database: database)

        XCTAssertEqual(lyrics?.lines.first?.text, "Found remotely")
    }

    func testFindsLyricsInsideIndexedHiddenPackageFolder() async throws {
        let root = try makeRoot()
        let music = root.appending(path: "Music", directoryHint: .isDirectory)
        let lyricsFolder = root.appending(path: ".Lyrics/Album.bundle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lyricsFolder, withIntermediateDirectories: true)
        let audio = music.appending(path: "Song.mp3")
        let indexedLyrics = lyricsFolder.appending(path: "Song.lrc")
        try Data().write(to: audio)
        try "[00:00]Hidden lyrics".write(to: indexedLyrics, atomically: true, encoding: .utf8)
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
         _ = try database.save(
             track: Track(
                 path: audio.path,
                 title: "Song",
                 artistDisplay: "",
                 albumTitle: "",
                 genreDisplay: "",
                 duration: 0,
                 format: "mp3"
             ),
             rootID: rootID
         )
        try database.registerLyricFile(indexedLyrics, forTrackPath: audio.path)

        let lyrics = try await LRCLyricsLoader().lyrics(for: audio, database: database)

        XCTAssertEqual(lyrics?.lines.first?.text, "Hidden lyrics")
    }

    func testLegacyLibraryRootsDoNotTriggerRecursiveLookup() async throws {
        let root = try makeRoot()
        let music = root.appending(path: "Music", directoryHint: .isDirectory)
        let lyricsFolder = root.appending(path: "Nested/Lyrics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lyricsFolder, withIntermediateDirectories: true)
        let audio = music.appending(path: "Song.mp3")
        try Data().write(to: audio)
        try "[00:00]Unindexed".write(to: lyricsFolder.appending(path: "Song.lrc"), atomically: true, encoding: .utf8)

        let lyrics = try await LRCLyricsLoader().lyrics(for: audio, libraryRoots: [root])

        XCTAssertNil(lyrics)
    }

    func testInvalidSidecarDoesNotHideValidIndexedLibraryMatch() async throws {
        let root = try makeRoot()
        let music = root.appending(path: "Music", directoryHint: .isDirectory)
        let lyricsFolder = root.appending(path: "Lyrics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lyricsFolder, withIntermediateDirectories: true)
        let audio = music.appending(path: "Song.flac")
        let indexedLyrics = lyricsFolder.appending(path: "Song.lrc")
        try Data().write(to: audio)
        try "not timed".write(to: music.appending(path: "Song.lrc"), atomically: true, encoding: .utf8)
        try "[00:00]Fallback".write(to: indexedLyrics, atomically: true, encoding: .utf8)
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
         _ = try database.save(
             track: Track(
                 path: audio.path,
                 title: "Song",
                 artistDisplay: "",
                 albumTitle: "",
                 genreDisplay: "",
                 duration: 0,
                 format: "flac"
             ),
             rootID: rootID
         )
        try database.registerLyricFile(indexedLyrics, forTrackPath: audio.path)

        let loader = LRCLyricsLoader()
        let lyrics = try await loader.lyrics(for: audio, database: database)
        let lyricURL = try await loader.lyricFileURL(for: audio, database: database)

        XCTAssertEqual(lyrics?.lines.first?.text, "Fallback")
        XCTAssertEqual(lyricURL, indexedLyrics)
    }

    func testInvalidOnlyMatchSurfacesError() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "Song.flac")
        try Data().write(to: audio)
        try "not timed".write(to: root.appending(path: "Song.lrc"), atomically: true, encoding: .utf8)

        do {
            _ = try await LRCLyricsLoader().lyrics(for: audio, libraryRoots: [root])
            XCTFail("Expected invalid lyrics error")
        } catch LRCLyricsLoadError.invalidLyrics(let url) {
            XCTAssertEqual(url.lastPathComponent, "Song.lrc")
        }
    }

    func testOversizedMatchIsRejectedBeforeReading() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "Song.flac")
        let sidecar = root.appending(path: "Song.lrc")
        try Data().write(to: audio)
        try Data(repeating: 65, count: 2 * 1_024 * 1_024 + 1).write(to: sidecar)

        do {
            _ = try await LRCLyricsLoader().lyrics(for: audio, libraryRoots: [root])
            XCTFail("Expected size limit error")
        } catch LRCLyricsLoadError.tooLarge(let url) {
            XCTAssertEqual(url, sidecar)
        }
    }

    func testCancelledLookupThrowsCancellation() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "Song.flac")
        try Data().write(to: audio)
        let loader = LRCLyricsLoader()
        let task = Task {
            await Task.yield()
            return try await loader.lyrics(for: audio, libraryRoots: [root])
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    func testExactSidecarLookupHandlesLargeDirectory() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "Song.flac")
        let sidecar = root.appending(path: "Song.lrc")
        try Data().write(to: audio)
        try "[00:00]Exact".write(to: sidecar, atomically: true, encoding: .utf8)
        for index in 0..<(LRCLyricsFileSystemSupport.maximumDirectoryEntryCount + 512) {
            try Data().write(to: root.appending(path: "Noise-\(index).bin"))
        }

        let lyrics = try await LRCLyricsLoader().lyrics(for: audio, libraryRoots: [root])

        XCTAssertEqual(lyrics?.lines.first?.text, "Exact")
    }

}
