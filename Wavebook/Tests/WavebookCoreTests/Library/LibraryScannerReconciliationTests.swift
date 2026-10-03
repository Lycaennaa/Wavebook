import Foundation
@testable import WavebookCore
import XCTest

extension LibraryScannerTests {
    func testLyricsAvailabilityWorksAcrossRootsHiddenFoldersDeletionAndReopen() async throws {
        let storage = try makeRoot()
        let audioRoot = storage.appending(path: "Audio", directoryHint: .isDirectory)
        let lyricsRoot = storage.appending(path: "Lyrics", directoryHint: .isDirectory)
        let hiddenLyrics = lyricsRoot.appending(path: ".Stored/Album.bundle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenLyrics, withIntermediateDirectories: true)
        try writeWAV(to: audioRoot.appending(path: "Song.wav"))
        let lyricURL = hiddenLyrics.appending(path: "song.LRC")
        try "[00:00]Lyrics".write(to: lyricURL, atomically: true, encoding: .utf8)
        let databaseURL = storage.appending(path: "Library.sqlite")
        let scanner = LibraryScanner()

        do {
            let database = try LibraryDatabase(path: databaseURL.path)
            try await scanner.scan(root: audioRoot, database: database)
            XCTAssertFalse(try XCTUnwrap(database.tracks().first).hasLyrics)
            let discoveredLyrics = try await scanner.discoverLyricFiles(in: lyricsRoot)
            XCTAssertEqual(discoveredLyrics.count, 1)
            try await scanner.scan(root: lyricsRoot, database: database)
            let indexedLyricFiles = try database.lyricFiles(forTrackPath: audioRoot.appending(path: "Song.wav").path)
            XCTAssertEqual(indexedLyricFiles.count, 1)
            XCTAssertTrue(try XCTUnwrap(database.tracks().first).hasLyrics)
        }

        let reopened = try LibraryDatabase(path: databaseURL.path)
        XCTAssertTrue(try XCTUnwrap(reopened.tracks().first).hasLyrics)
        try FileManager.default.removeItem(at: lyricURL)
        try await scanner.scan(root: lyricsRoot, database: reopened)
        XCTAssertFalse(try XCTUnwrap(reopened.tracks().first).hasLyrics)
    }

    func testCorruptCandidateDoesNotBlockLyricReconciliation() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "One.wav")
        let lyrics = root.appending(path: "One.lrc")
        try writeWAV(to: audio)
        try "[00:00]Lyrics".write(to: lyrics, atomically: true, encoding: .utf8)
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        try await scanner.scan(root: root, database: database)
        XCTAssertTrue(try XCTUnwrap(database.tracks().first).hasLyrics)

        try FileManager.default.removeItem(at: lyrics)
        try Data().write(to: root.appending(path: "Broken.wav"))
        try await scanner.scan(root: root, database: database)

        XCTAssertFalse(try XCTUnwrap(database.tracks().first).hasLyrics)
    }

    func testUnchangedAudioResultRefreshesLyricAvailability() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "One.wav")
        let lyrics = root.appending(path: "One.lrc")
        try writeWAV(to: audio)
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()

        let initial = try await scanner.scan(root: root, database: database)
        XCTAssertFalse(try XCTUnwrap(initial.tracks.first).hasLyrics)

        try "[00:00]Lyrics".write(to: lyrics, atomically: true, encoding: .utf8)
        let withLyrics = try await scanner.scan(root: root, database: database)
        XCTAssertTrue(try XCTUnwrap(withLyrics.tracks.first).hasLyrics)

        try FileManager.default.removeItem(at: lyrics)
        let withoutLyrics = try await scanner.scan(root: root, database: database)
        XCTAssertFalse(try XCTUnwrap(withoutLyrics.tracks.first).hasLyrics)
    }

    func testCancelledScanKeepsPreviousSnapshot() async throws {
        let root = try makeRoot()
        try writeWAV(to: root.appending(path: "One.wav"))
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        try await scanner.scan(root: root, database: database)
        let completedAt = try XCTUnwrap(database.roots().first?.lastScanAt)

        try writeWAV(to: root.appending(path: "Two.wav"))
        let started = AsyncStream<Void>.makeStream()
        let proceed = AsyncStream<Void>.makeStream()
        let scanTask = Task { () throws -> LibraryScanResult in
            started.continuation.yield(())
            for await _ in proceed.stream { break }
            return try await scanner.scan(root: root, database: database)
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        scanTask.cancel()
        proceed.continuation.yield(())
        proceed.continuation.finish()

        do {
            _ = try await scanTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(try database.tracks().map(\.title), ["One"])
        XCTAssertEqual(try database.roots().first?.lastScanAt, completedAt)
    }

    func testCancelledUnchangedScanDoesNotAdvanceLastScanAt() async throws {
        let root = try makeRoot()
        try writeWAV(to: root.appending(path: "One.wav"))
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        try await scanner.scan(root: root, database: database)
        let completedAt = try XCTUnwrap(database.roots().first?.lastScanAt)
        let probe = CatalogReconcileCancellationProbe(
            phase: .unchangedScanTimestampUpdated,
            cancellationCheckpoint: 1
        )

        let scanTask = CatalogReconcileTesting.$checkpointHandler.withValue(
            { phase in probe.checkpoint(phase) },
            operation: {
                LibraryDatabase.withCatalogCancellationToken(
                    probe.token,
                    operation: {
                        Task { () -> Result<LibraryScanResult, Error> in
                            do {
                                return .success(try await scanner.scan(root: root, database: database))
                            } catch {
                                return .failure(error)
                            }
                        }
                    }
                )
            }
        )
        switch await scanTask.value {
        case .success:
            XCTFail("Expected cancellation")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(try database.roots().first?.lastScanAt, completedAt)
        XCTAssertEqual(try database.tracks().map(\.title), ["One"])
    }

    func testMissingRootScanRemainsFatalAndPreservesSnapshot() async throws {
        let root = try makeRoot()
        try writeWAV(to: root.appending(path: "One.wav"))
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        try await scanner.scan(root: root, database: database)
        let completedAt = try XCTUnwrap(database.roots().first?.lastScanAt)

        do {
             _ = try await scanner.scan(
                 root: root.appending(path: "Missing", directoryHint: .isDirectory),
                 database: database
             )
            XCTFail("Expected root enumeration failure")
        } catch {
            // Root access errors are fatal without requiring one concrete filesystem error type.
        }

        XCTAssertEqual(try database.tracks().map(\.title), ["One"])
        XCTAssertEqual(try database.roots().first?.lastScanAt, completedAt)
    }
    func testDisappearingCandidateIsDiagnosedAndRetained() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "One.wav")
        try writeWAV(to: audio)
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        try await scanner.scan(root: root, database: database)

        try FileManager.default.removeItem(at: audio)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: false)
        let result = try await scanner.scan(root: root, database: database)

        XCTAssertEqual(result.failedCandidateCount, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try database.tracks().map(\.title), ["One"])
    }

    func testUnresolvableDescendantCandidateRetainsCatalogIdentityAndFavorite() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "One.wav")
        try writeWAV(to: audio)
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        try await scanner.scan(root: root, database: database)
        let originalTrack = try XCTUnwrap(database.tracks().first)
        let originalID = try XCTUnwrap(originalTrack.id)
        _ = try database.setFavorite(trackID: originalID, isFavorite: true)

        try FileManager.default.removeItem(at: audio)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: audio)
        let result = try await scanner.scan(root: root, database: database)

        XCTAssertEqual(result.failedCandidateCount, 1)
        let storedIDs = try await database.writer.read { connection in
            try Int64.fetchAll(connection, sql: "SELECT id FROM tracks ORDER BY id")
        }
        let favoriteIDs = try await database.writer.read { connection in
            try Int64.fetchAll(connection, sql: "SELECT id FROM tracks WHERE isFavorite = 1 ORDER BY id")
        }
        XCTAssertEqual(storedIDs, [originalID])
        XCTAssertEqual(favoriteIDs, [originalID])
    }

    func testPreservationPathLimitAbortsBeforePruningExistingTrack() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "One.wav")
        let audioLikeDirectory = root.appending(path: "Unreadable.wav", directoryHint: .isDirectory)
        try writeWAV(to: audio)
        try FileManager.default.createDirectory(at: audioLikeDirectory, withIntermediateDirectories: true)
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner(preservedFailurePathLimit: 1)
        try await scanner.scan(root: root, database: database)
        let originalTrack = try XCTUnwrap(database.tracks().first)
        let originalID = try XCTUnwrap(originalTrack.id)
        _ = try database.setFavorite(trackID: originalID, isFavorite: true)

        try FileManager.default.removeItem(at: audio)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: audio)
        do {
            _ = try await scanner.scan(root: root, database: database)
            XCTFail("A scan exceeding the preservation limit must not reconcile the catalog")
        } catch let error as LibraryScannerError {
            guard case let .tooManyPreservedFailurePaths(_, limit) = error else {
                XCTFail("Unexpected scanner error: \(error)")
                return
            }
            XCTAssertEqual(limit, 1)
        }

        let storedIDs = try await database.writer.read { connection in
            try Int64.fetchAll(connection, sql: "SELECT id FROM tracks ORDER BY id")
        }
        let favoriteIDs = try await database.writer.read { connection in
            try Int64.fetchAll(connection, sql: "SELECT id FROM tracks WHERE isFavorite = 1 ORDER BY id")
        }
        XCTAssertEqual(storedIDs, [originalID])
        XCTAssertEqual(favoriteIDs, [originalID])
    }

    func testDiscoveryEntryLimitIgnoresUnrelatedFilesAndPreservesCatalog() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "One.wav")
        try writeWAV(to: audio)
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner(
            preservedFailurePathLimit: 50_000,
            maximumDiscoveredEntryCount: 2
        )
        try await scanner.scan(root: root, database: database)
        let originalTrack = try XCTUnwrap(database.tracks().first)
        let originalID = try XCTUnwrap(originalTrack.id)
        _ = try database.setFavorite(trackID: originalID, isFavorite: true)

        for name in ["Notes.txt", "Readme.md", "unrelated.jpg"] {
            try Data().write(to: root.appending(path: name))
        }
        try await scanner.scan(root: root, database: database)
        XCTAssertEqual(try database.tracks().map(\.id), [originalID])

        try "[00:00]Lyrics".write(to: root.appending(path: "One.lrc"), atomically: true, encoding: .utf8)
        try await scanner.scan(root: root, database: database)
        XCTAssertTrue(try XCTUnwrap(database.tracks().first).hasLyrics)

        try Data().write(to: root.appending(path: "cover.jpg"))
        do {
            _ = try await scanner.scan(root: root, database: database)
            XCTFail("A scan exceeding the relevant-entry limit must not reconcile the catalog")
        } catch let error as LibraryScannerError {
            guard case let .tooManyDiscoveredEntries(_, limit) = error else {
                XCTFail("Unexpected scanner error: \(error)")
                return
            }
            XCTAssertEqual(limit, 2)
        }

        let storedTrack = try XCTUnwrap(database.tracks().first)
        XCTAssertEqual(storedTrack.id, originalID)
        XCTAssertTrue(storedTrack.isFavorite)
        XCTAssertTrue(storedTrack.hasLyrics)
    }

    func testDescendantSymlinkOutsideRootIsNeverCatalogued() async throws {
        let root = try makeRoot()
        let foreign = root.deletingLastPathComponent().appending(path: "foreign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let foreignAudio = foreign.appending(path: "Foreign.wav")
        try writeWAV(to: foreignAudio)
        let alias = root.appending(path: "External", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: foreign)
        }

        let database = try LibraryDatabase(inMemory: true)
        let result = try await LibraryScanner().scan(root: root, database: database)

        XCTAssertTrue(try database.tracks().isEmpty)
        XCTAssertFalse(result.tracks.contains { $0.path == foreignAudio.path })
    }

}
