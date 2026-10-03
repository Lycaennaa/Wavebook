import Foundation
@testable import WavebookCore
import XCTest

extension LibraryScannerTests {
    func testScanAddsAndPrunesOnlyChangedTracks() async throws {
        let root = try makeRoot()
        let firstAudio = root.appending(path: "One.wav")
        let secondAudio = root.appending(path: "Two.wav")
        try writeWAV(to: firstAudio)
        try Data().write(to: root.appending(path: "Notes.txt"))

        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        let firstResult = try await scanner.scan(root: root, database: database)
        XCTAssertEqual(firstResult.tracks.map(\.title), ["One"])
        let firstID = try XCTUnwrap(firstResult.tracks.first?.id)

        try writeWAV(to: secondAudio)
        let addedResult = try await scanner.scan(root: root, database: database)
        XCTAssertEqual(addedResult.tracks.map(\.title), ["One", "Two"])
        XCTAssertEqual(addedResult.tracks.first?.id, firstID)

        try FileManager.default.removeItem(at: secondAudio)
        let removedResult = try await scanner.scan(root: root, database: database)
        XCTAssertEqual(removedResult.tracks.map(\.title), ["One"])
        XCTAssertEqual(removedResult.tracks.first?.id, firstID)
        XCTAssertEqual(try database.tracks().map(\.title), ["One"])
    }

    func testUnchangedAliasCannotHideAnotherDeletedTrack() async throws {
        let root = try makeRoot()
        let firstAudio = root.appending(path: "One.wav")
        let deletedAudio = root.appending(path: "Two.wav")
        try writeWAV(to: firstAudio)
        try writeWAV(to: deletedAudio)
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        _ = try await scanner.scan(root: root, database: database)

        try FileManager.default.removeItem(at: deletedAudio)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "Alias.wav"),
            withDestinationURL: firstAudio
        )
        _ = try await scanner.scan(root: root, database: database)

        XCTAssertEqual(try database.tracks().map(\.path), [try LibraryDatabase.resolveRootPath(firstAudio.path)])
    }

    func testChangedTrackWithInRootAliasReturnsOnePersistedSnapshot() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "One.wav")
        try writeWAV(to: audio)
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        let initialScan = try await scanner.scan(root: root, database: database)
        let originalID = try XCTUnwrap(initialScan.tracks.first?.id)

        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "Alias.wav"),
            withDestinationURL: audio
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 978_307_200)],
            ofItemAtPath: audio.path
        )
        let changedScan = try await scanner.scan(root: root, database: database)
        let canonicalPath = try LibraryDatabase.resolveRootPath(audio.path)

        XCTAssertEqual(changedScan.tracks.count, 1)
        XCTAssertEqual(changedScan.tracks.first?.path, canonicalPath)
        XCTAssertEqual(changedScan.tracks.first?.id, originalID)
        XCTAssertEqual(try database.tracks().map(\.path), [canonicalPath])
    }

    func testAddingHardLinkKeepsBothCatalogPaths() async throws {
        let root = try makeRoot()
        let originalAudio = root.appending(path: "Original.wav")
        let aliasAudio = root.appending(path: "Alias.wav")
        try writeWAV(to: originalAudio)
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        let initialScan = try await scanner.scan(root: root, database: database)
        let originalID = try XCTUnwrap(initialScan.tracks.first?.id)

        try FileManager.default.linkItem(at: originalAudio, to: aliasAudio)
        let addedScan = try await scanner.scan(root: root, database: database)
        let originalPath = try LibraryDatabase.resolveRootPath(originalAudio.path)
        let aliasPath = try LibraryDatabase.resolveRootPath(aliasAudio.path)
        let storedTracks = try database.tracks()

        XCTAssertEqual(addedScan.tracks.count, 2)
        XCTAssertEqual(Set(storedTracks.map(\.path)), Set([originalPath, aliasPath]))
        XCTAssertEqual(Set(storedTracks.compactMap(\.id)).count, 2)
        XCTAssertEqual(storedTracks.first { $0.path == originalPath }?.id, originalID)
    }

    func testRescanReusesMetadataAndReconcilesOnlyChangedTrack() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "One.wav")
        let otherAudio = root.appending(path: "Two.wav")
        try writeWAV(to: audio)
        try writeWAV(to: otherAudio)
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        let firstScan = try await scanner.scan(root: root, database: database)
        let firstTrack = try XCTUnwrap(firstScan.tracks.first { $0.path == audio.path })
        let firstID = try XCTUnwrap(firstTrack.id)
        let otherTrack = try XCTUnwrap(firstScan.tracks.first { $0.path == otherAudio.path })
        let otherID = try XCTUnwrap(otherTrack.id)
        _ = try database.setFavorite(trackID: otherID, isFavorite: true)
        _ = try database.setFavorite(trackID: firstID, isFavorite: true)

        var cachedTrack = firstTrack
        cachedTrack.title = "Cached title"
        let rootID = try XCTUnwrap(database.roots().first?.id)
        _ = try database.save(track: cachedTrack, rootID: rootID)

        let unchangedScan = try await scanner.scan(root: root, database: database)
        XCTAssertEqual(unchangedScan.tracks.first { $0.path == audio.path }?.title, "Cached title")

        let changedDate = Date(timeIntervalSince1970: 978_307_200)
        try FileManager.default.setAttributes([.modificationDate: changedDate], ofItemAtPath: audio.path)
        let changedScan = try await scanner.scan(root: root, database: database)
        let updatedTrack = try XCTUnwrap(changedScan.tracks.first { $0.path == audio.path })
        let unchangedTrack = try XCTUnwrap(changedScan.tracks.first { $0.path == otherAudio.path })
        XCTAssertEqual(updatedTrack.title, "One")
        XCTAssertEqual(updatedTrack.id, firstID)
        XCTAssertEqual(unchangedTrack.id, otherID)
        XCTAssertTrue(updatedTrack.isFavorite)
        XCTAssertTrue(unchangedTrack.isFavorite)
    }

    func testPathOrderingBreaksLocalizedTiesByRawPath() {
        let uppercase = "/library/Track 1.wav"
        let lowercase = "/library/track 1.wav"

        XCTAssertEqual(
            CatalogFacetOrdering.rawTieBrokenComparison(localized: .orderedSame, lhs: uppercase, rhs: lowercase),
            .orderedAscending
        )
        XCTAssertEqual(
            CatalogFacetOrdering.rawTieBrokenComparison(localized: .orderedSame, lhs: lowercase, rhs: uppercase),
            .orderedDescending
        )
    }

    func testCorruptCandidateDoesNotBlockValidCatalogState() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "One.wav")
        try writeWAV(to: audio)
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        try await scanner.scan(root: root, database: database)

        let broken = root.appending(path: "Broken.wav")
        try Data().write(to: broken)
        let result = try await scanner.scan(root: root, database: database)

        XCTAssertEqual(result.tracks.map(\.title), ["One"])
        XCTAssertEqual(result.failedCandidateCount, 1)
        XCTAssertEqual(result.omittedFailureCount, 0)
        let diagnostic = try XCTUnwrap(result.failures.first)
        XCTAssertEqual(diagnostic.path, broken.standardizedFileURL.path)
        XCTAssertFalse(diagnostic.reason.isEmpty)
        XCTAssertEqual(try database.tracks().map(\.title), ["One"])
        XCTAssertNotNil(try database.roots().first?.lastScanAt)
    }

    func testOversizedMetadataCandidateDoesNotBlockValidCatalogState() async throws {
        let root = try makeRoot()
        try writeWAV(to: root.appending(path: "One.wav"))
        try writeOversizedID3(to: root.appending(path: "Broken.mp3"))
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()

        let result = try await scanner.scan(root: root, database: database)

        XCTAssertEqual(result.tracks.map(\.title), ["One"])
        XCTAssertEqual(result.failedCandidateCount, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.path, root.appending(path: "Broken.mp3").standardizedFileURL.path)
        XCTAssertFalse(result.failures.first?.reason.isEmpty ?? true)
        XCTAssertEqual(try database.tracks().map(\.title), ["One"])
    }

    func testScanBoundsFailureDiagnostics() async throws {
        let root = try makeRoot()
        for index in 0..<101 {
            try Data().write(to: root.appending(path: "Broken-\(index).wav"))
        }
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()

        let result = try await scanner.scan(root: root, database: database)

        XCTAssertEqual(result.failedCandidateCount, 101)
        XCTAssertEqual(result.failures.count, 100)
        XCTAssertEqual(result.omittedFailureCount, 1)
    }

    func testCorruptExistingCandidateIsRetainedWhileValidFilesReconcile() async throws {
        let root = try makeRoot()
        let one = root.appending(path: "One.wav")
        let two = root.appending(path: "Two.wav")
        try writeWAV(to: one)
        try writeWAV(to: two)
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        try await scanner.scan(root: root, database: database)

        try Data().write(to: two)
        try writeWAV(to: root.appending(path: "Three.wav"))
        try await scanner.scan(root: root, database: database)

        XCTAssertEqual(try database.tracks().map(\.title), ["One", "Three", "Two"])
    }

    func testCorruptExistingCandidateOutsideFirstPageIsRetained() async throws {
        let root = try makeRoot()
        let rootPath = root.standardizedFileURL.path
        let failedURL = root.appending(path: "Failed.wav")
        try writeWAV(to: root.appending(path: "One.wav"))
        try Data().write(to: failedURL)

        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: rootPath)
        for index in 0..<500 {
            let path = root.appending(path: "Existing-\(index).wav").path
            _ = try database.save(
                 track: Track(
                     path: path,
                     title: "Existing-\(index)",
                     artistDisplay: "Artist",
                     albumTitle: "Album",
                     genreDisplay: "Genre",
                     duration: 1,
                     format: "wav"
                 ),
                rootID: rootID
            )
        }
        _ = try database.save(
             track: Track(
                 path: failedURL.path,
                 title: "ZZZ Failed",
                 artistDisplay: "Artist",
                 albumTitle: "Album",
                 genreDisplay: "Genre",
                 duration: 1,
                 format: "wav"
             ),
            rootID: rootID
        )

        let scanner = LibraryScanner()
        let result = try await scanner.scan(root: root, database: database)

        XCTAssertEqual(result.failedCandidateCount, 1)
        XCTAssertEqual(try database.tracks().map(\.title), ["One", "ZZZ Failed"])
    }

    func testChangedCorruptCandidateRetainsMetadataAndInvalidatesReplayGain() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "One.wav")
        try writeWAV(to: audio)
        let database = try LibraryDatabase(inMemory: true)
        let scanner = LibraryScanner()
        try await scanner.scan(root: root, database: database)

        let trackID = try XCTUnwrap(database.tracks().first?.id)
        let pending = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        let oldValues = ReplayGainScopeValues(
            gain: ReplayGainGain(decibels: -3, source: .measured),
            samplePeak: 0.5
        )
        XCTAssertTrue(try database.commitReplayGainTrackResult(
            trackID: trackID,
            fingerprint: pending.fingerprint,
            claimToken: pending.claimToken,
            values: oldValues
        ))
        let oldData = try XCTUnwrap(database.replayGainData(trackID: trackID))
        XCTAssertEqual(oldData.state, .ready)
        XCTAssertEqual(oldData.track, oldValues)

        try Data().write(to: audio)
        let currentFingerprint = LibraryDatabase.fileFingerprint(path: audio.path)

        let result = try await scanner.scan(root: root, database: database)

        XCTAssertEqual(result.failedCandidateCount, 1)
        let retainedTrack = try XCTUnwrap(database.tracks().first)
        XCTAssertEqual(retainedTrack.id, trackID)
        XCTAssertEqual(retainedTrack.title, "One")
        let updatedData = try XCTUnwrap(database.replayGainData(trackID: trackID))
        XCTAssertEqual(updatedData.state, .pending)
        XCTAssertNil(updatedData.track)
        XCTAssertNotEqual(updatedData.fingerprint, oldData.fingerprint)
        XCTAssertEqual(updatedData.fingerprint, currentFingerprint)
        XCTAssertEqual(try database.replayGainStatusCounts(), ReplayGainAnalysisStatusCounts(pending: 1))
    }
}
