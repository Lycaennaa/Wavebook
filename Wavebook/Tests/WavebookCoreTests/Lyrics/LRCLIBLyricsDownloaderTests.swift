import Foundation
import GRDB
@testable import WavebookCore
import XCTest

final class LRCLIBLyricsDownloaderTests: XCTestCase {
    func testDownloadsSyncedLyricsUsingLRCGETMetadataRequest() async throws {
        let root = try makeRoot()
        let audio = try makeAudio(in: root)
        let body = Data(#"""
        {
          "id": 1,
          "trackName": "Song",
          "artistName": "Artist",
          "albumName": "Album",
          "duration": 180.2,
          "instrumental": false,
          "plainLyrics": "Line",
          "syncedLyrics": "[00:01.00]Line"
        }
        """#.utf8)
        let downloader = LRCLIBLyricsDownloader { request in
            guard request.url?.path == "/api/get",
                  request.value(forHTTPHeaderField: "User-Agent") == "LRCGET v2.1.0 (https://github.com/tranxuanthang/lrcget)",
                  queryValue("track_name", in: request.url) == "Song",
                  queryValue("artist_name", in: request.url) == "Artist",
                  queryValue("album_name", in: request.url) == "Album",
                  queryValue("duration", in: request.url) == "180" else {
                throw TestFailure.invalidRequest
            }
            return (body, response(for: request, statusCode: 200))
        }

        let result = try await downloader.downloadLyrics(for: track(path: audio.path))

        XCTAssertTrue(result.lyrics.isSynchronized)
        XCTAssertEqual(result.lyrics.lines.first?.text, "Line")
        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), "[00:01.00]Line")
    }

    func testSearchSendsOnlySelectedMetadataAndDownloadsInstrumentalMarker() async throws {
        let root = try makeRoot()
        let audio = try makeAudio(in: root)
        let body = Data(#"""
        [
          {
            "id": 42,
            "trackName": "Song",
            "artistName": "Artist",
            "albumName": "Album",
            "duration": 1e100,
            "instrumental": true,
            "plainLyrics": null,
            "syncedLyrics": null
          }
        ]
        """#.utf8)
        let downloader = LRCLIBLyricsDownloader { request in
            guard request.url?.path == "/api/search",
                  request.value(forHTTPHeaderField: "User-Agent") == "LRCGET v2.1.0 (https://github.com/tranxuanthang/lrcget)",
                  queryValue("track_name", in: request.url) == nil,
                  queryValue("artist_name", in: request.url) == "Artist",
                  queryValue("album_name", in: request.url) == nil,
                  queryValue("q", in: request.url) == "live" else {
                throw TestFailure.invalidRequest
            }
            return (body, response(for: request, statusCode: 200))
        }

        let results = try await downloader.searchLyrics(LRCLIBLyricsSearchQuery(artistName: "Artist", keywords: "live"))
        let selected = try XCTUnwrap(results.first)
        let download = try await downloader.downloadLyrics(selected, for: track(path: audio.path))
        let reloaded = try await LRCLyricsLoader().lyrics(for: audio, libraryRoots: [root])

        XCTAssertTrue(selected.isInstrumental)
        XCTAssertNil(selected.duration)
        XCTAssertEqual(selected.previewLyrics?.lines.map(\.text), ["Instrumental"])
        XCTAssertEqual(try String(contentsOf: download.fileURL, encoding: .utf8), "[au: instrumental]")
        XCTAssertFalse(download.lyrics.isSynchronized)
        XCTAssertEqual(download.lyrics.lines.map(\.text), ["Instrumental"])
        XCTAssertEqual(reloaded, download.lyrics)
    }

    func testSearchResultsExposeSyncedAndPlainLyricsForPreview() async throws {
        let root = try makeRoot()
        let audio = try makeAudio(in: root)
        let body = Data(#"""
        [
          {"id":1,"trackName":"Synced","artistName":"Artist","albumName":"Album","duration":180,"instrumental":false,
           "plainLyrics":"Plain fallback","syncedLyrics":"[00:01.00]First\n[00:02.00]Second"},
          {"id":2,"trackName":"Plain","artistName":"Artist","albumName":"Album","duration":180,"instrumental":false,
           "plainLyrics":"First\nSecond","syncedLyrics":null},
          {"id":3,"trackName":"Fallback","artistName":"Artist","albumName":"Album","duration":180,"instrumental":false,
           "plainLyrics":"Usable plain lyrics","syncedLyrics":"not timed"}
        ]
        """#.utf8)
        let downloader = LRCLIBLyricsDownloader { request in
            (body, response(for: request, statusCode: 200))
        }

        let results = try await downloader.searchLyrics(LRCLIBLyricsSearchQuery(keywords: "preview"))

        XCTAssertEqual(results[0].previewLyrics?.lines.map(\.text), ["First", "Second"])
        XCTAssertTrue(results[0].previewLyrics?.isSynchronized == true)
        XCTAssertEqual(results[0].previewLyrics?.lineIndex(at: 1.2), 0)
        XCTAssertEqual(results[0].previewLyrics?.lineIndex(at: 2.2), 1)
        XCTAssertEqual(results[1].previewLyrics?.lines.map(\.text), ["First", "Second"])
        XCTAssertFalse(results[1].previewLyrics?.isSynchronized == true)
        XCTAssertNil(results[1].previewLyrics?.lineIndex(at: 2.2))
        XCTAssertEqual(results[2].previewLyrics?.lines.map(\.text), ["Usable plain lyrics"])
        XCTAssertFalse(results[2].hasSyncedLyrics)
        XCTAssertTrue(results[2].hasPlainLyrics)

        let fallback = try await downloader.downloadLyrics(results[2], for: track(path: audio.path))
        XCTAssertFalse(fallback.lyrics.isSynchronized)
        XCTAssertEqual(fallback.lyrics.lines.map(\.text), ["Usable plain lyrics"])
    }

    func testPersistsAndReloadsPlainLyricsWhenNoSyncedResultExists() async throws {
        let root = try makeRoot()
        let audio = try makeAudio(in: root)
        let directBody = Data(#"""
        {
          "id": 1,
          "trackName": "Song",
          "artistName": "Artist",
          "albumName": "Album",
          "duration": 180,
          "instrumental": false,
          "plainLyrics": "First line\nSecond line",
          "syncedLyrics": null
        }
        """#.utf8)
        let downloader = LRCLIBLyricsDownloader { request in
            switch request.url?.path {
            case "/api/get":
                return (directBody, response(for: request, statusCode: 200))
            case "/api/search":
                return (Data("[]".utf8), response(for: request, statusCode: 200))
            default:
                throw TestFailure.invalidRequest
            }
        }

        let result = try await downloader.downloadLyrics(for: track(path: audio.path))
        let reloaded = try await LRCLyricsLoader().lyrics(for: audio, libraryRoots: [root])

        XCTAssertFalse(result.lyrics.isSynchronized)
        XCTAssertEqual(result.lyrics.lines.map(\.text), ["First line", "Second line"])
        XCTAssertEqual(reloaded, result.lyrics)
        XCTAssertNil(result.lyrics.lineIndex(at: 30))
    }

    func testFallsBackToConservativeSearchAndPrefersSyncedClosestMatch() async throws {
        let root = try makeRoot()
        let audio = try makeAudio(in: root)
        let searchBody = Data(#"""
        [
          {"id":3,"trackName":"Song","artistName":"Artist","albumName":"Other","duration":181,"instrumental":false,
           "plainLyrics":"Plain","syncedLyrics":null},
          {"id":2,"trackName":"Song","artistName":"Artist","albumName":"Album","duration":181.5,"instrumental":false,
           "plainLyrics":"Right","syncedLyrics":"[00:02]Right"},
          {"id":1,"trackName":"Song","artistName":"Artist","albumName":"Album","duration":240,"instrumental":false,
           "plainLyrics":"Wrong","syncedLyrics":"[00:02]Wrong"}
        ]
        """#.utf8)
        let downloader = LRCLIBLyricsDownloader { request in
            switch request.url?.path {
            case "/api/get":
                return (Data(), response(for: request, statusCode: 404))
            case "/api/search":
                guard queryValue("track_name", in: request.url) == "Song",
                      queryValue("artist_name", in: request.url) == "Artist" else {
                    throw TestFailure.invalidRequest
                }
                return (searchBody, response(for: request, statusCode: 200))
            default:
                throw TestFailure.invalidRequest
            }
        }

        let result = try await downloader.downloadLyrics(for: track(path: audio.path))

        XCTAssertEqual(result.lyrics.lines.first?.text, "Right")
    }

}

extension LRCLIBLyricsDownloaderTests {
    func testRejectsMismatchedDirectResponseBeforeWriting() async throws {
        let root = try makeRoot()
        let audio = try makeAudio(in: root)
        let directBody = Data(#"""
        {
          "id": 1,
          "trackName": "Different Song",
          "artistName": "Other Artist",
          "albumName": "Album",
          "duration": 180,
          "instrumental": false,
          "plainLyrics": "Wrong",
          "syncedLyrics": "[00:01]Wrong"
        }
        """#.utf8)
        let downloader = LRCLIBLyricsDownloader { request in
            switch request.url?.path {
            case "/api/get":
                return (directBody, response(for: request, statusCode: 200))
            case "/api/search":
                return (Data("[]".utf8), response(for: request, statusCode: 200))
            default:
                throw TestFailure.invalidRequest
            }
        }

        do {
            _ = try await downloader.downloadLyrics(for: track(path: audio.path))
            XCTFail("Expected not found error")
        } catch let error as LRCLIBLyricsDownloadError {
            XCTAssertEqual(error, .notFound)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: audio.deletingPathExtension().appendingPathExtension("lrc").path
            )
        )
    }

    func testRejectsDirectResponseWithoutTrackIdentity() async throws {
        let root = try makeRoot()
        let audio = try makeAudio(in: root)
        let directBody = Data(#"""
        {
          "id": 1,
          "duration": 180,
          "instrumental": false,
          "plainLyrics": "Wrong",
          "syncedLyrics": "[00:01]Wrong"
        }
        """#.utf8)
        let downloader = LRCLIBLyricsDownloader { request in
            switch request.url?.path {
            case "/api/get":
                return (directBody, response(for: request, statusCode: 200))
            case "/api/search":
                return (Data("[]".utf8), response(for: request, statusCode: 200))
            default:
                throw TestFailure.invalidRequest
            }
        }

        do {
            _ = try await downloader.downloadLyrics(for: track(path: audio.path))
            XCTFail("Expected not found error")
        } catch let error as LRCLIBLyricsDownloadError {
            XCTAssertEqual(error, .notFound)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: audio.deletingPathExtension().appendingPathExtension("lrc").path
            )
        )
    }

    func testServerFailureDoesNotOverwriteExistingLyrics() async throws {
        let root = try makeRoot()
        let audio = try makeAudio(in: root)
        let existing = audio.deletingPathExtension().appendingPathExtension("lrc")
        try "[00:00]Existing".write(to: existing, atomically: true, encoding: .utf8)
        let downloader = LRCLIBLyricsDownloader { request in
            let body = Data(#"{"message":"Service unavailable"}"#.utf8)
            return (body, response(for: request, statusCode: 503))
        }

        do {
            _ = try await downloader.downloadLyrics(for: track(path: audio.path))
            XCTFail("Expected server error")
        } catch let error as LRCLIBLyricsDownloadError {
            XCTAssertEqual(error, .server(statusCode: 503, message: "Service unavailable"))
        }

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "[00:00]Existing")
    }

    func testRegisterLyricFileUpdatesAvailabilityWithoutRescan() throws {
        let root = try makeRoot()
        let audio = try makeAudio(in: root)
        let lyricURL = audio.deletingPathExtension().appendingPathExtension("lrc")
        try "[00:00]Lyrics".write(to: lyricURL, atomically: true, encoding: .utf8)
        let database = try LibraryDatabase(inMemory: true)
        try database.reconcile(rootPath: root.path, tracks: [track(path: audio.path)], lyricFiles: [])

        XCTAssertFalse(try XCTUnwrap(database.tracks().first).hasLyrics)
        try database.registerLyricFile(lyricURL, forTrackPath: audio.path)
         let firstRegistrationID = try database.writer.read { reader in
             try XCTUnwrap(
                 Int64.fetchOne(
                     reader,
                     sql: "SELECT id FROM lyricFiles WHERE path = ?",
                     arguments: [lyricURL.path]
                 )
             )
         }
        try database.registerLyricFile(lyricURL, forTrackPath: audio.path)
         let secondRegistrationID = try database.writer.read { reader in
             try XCTUnwrap(
                 Int64.fetchOne(
                     reader,
                     sql: "SELECT id FROM lyricFiles WHERE path = ?",
                     arguments: [lyricURL.path]
                 )
             )
         }
        XCTAssertEqual(firstRegistrationID, secondRegistrationID)
        XCTAssertTrue(try XCTUnwrap(database.tracks().first).hasLyrics)
    }

    func testDownloadUsesExpectedNameInLargeDirectory() async throws {
        let root = try makeRoot()
        let audio = try makeAudio(in: root)
        let expected = audio.deletingPathExtension().appendingPathExtension("lrc")
        let body = Data(#"""
        {
          "id": 1,
          "trackName": "Song",
          "artistName": "Artist",
          "albumName": "Album",
          "duration": 180,
          "instrumental": false,
          "plainLyrics": "Line",
          "syncedLyrics": "[00:01]Line"
        }
        """#.utf8)
        let downloader = LRCLIBLyricsDownloader { request in
            (body, response(for: request, statusCode: 200))
        }
        for index in 0..<(LRCLyricsFileSystemSupport.maximumDirectoryEntryCount + 512) {
            try Data().write(to: root.appending(path: "Noise-\(index).bin"))
        }

        let result = try await downloader.downloadLyrics(for: track(path: audio.path))

        XCTAssertEqual(result.fileURL, expected)
        XCTAssertEqual(try String(contentsOf: expected, encoding: .utf8), "[00:01]Line")
    }

    func testDownloadReusesCaseInsensitiveExistingSidecarName() async throws {
        let root = try makeRoot()
        let audio = try makeAudio(in: root)
        let existing = root.appending(path: "song.LRC")
        let expected = audio.deletingPathExtension().appendingPathExtension("lrc")
        try "[00:00]Old".write(to: existing, atomically: true, encoding: .utf8)
        let body = Data(#"""
        {
          "id": 1,
          "trackName": "Song",
          "artistName": "Artist",
          "albumName": "Album",
          "duration": 180,
          "instrumental": false,
          "plainLyrics": "Line",
          "syncedLyrics": "[00:01]Line"
        }
        """#.utf8)
        let downloader = LRCLIBLyricsDownloader { request in
            (body, response(for: request, statusCode: 200))
        }

        let result = try await downloader.downloadLyrics(for: track(path: audio.path))

        XCTAssertEqual(result.fileURL, existing)
        let directoryNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(directoryNames.contains(existing.lastPathComponent))
        XCTAssertFalse(directoryNames.contains(expected.lastPathComponent))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "[00:01]Line")
    }

    private func track(path: String) -> Track {
        Track(
            path: path,
            title: "Song",
            artistDisplay: "Artist",
            albumTitle: "Album",
            genreDisplay: "",
            duration: 180.2,
            format: "flac"
        )
    }

    private func makeAudio(in root: URL) throws -> URL {
        let audio = root.appending(path: "Song.flac")
        try Data().write(to: audio)
        return audio
    }

    private func makeRoot() throws -> URL {
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

private enum TestFailure: Error {
    case invalidRequest
}

private func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
    guard let url = request.url else {
        preconditionFailure("Test request must have a URL")
    }
    guard let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    ) else {
        preconditionFailure("Test response must be constructible")
    }
    return response
}

private func queryValue(_ name: String, in url: URL?) -> String? {
    guard let url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == name })?
        .value
}
