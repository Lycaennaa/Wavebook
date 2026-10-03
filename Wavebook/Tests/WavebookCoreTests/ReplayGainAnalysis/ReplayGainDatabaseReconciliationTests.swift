import Foundation
import GRDB
@testable import WavebookCore
import XCTest

extension ReplayGainDatabaseTests {
    func testAlbumCommitRejectsMembershipChangeWithoutPartialWrites() throws {
        let root = try makeRoot()
        let firstURL = try makeAudioFile(in: root, name: "one.flac")
        let secondURL = try makeAudioFile(in: root, name: "two.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let firstID = try database.save(
            track: track(for: firstURL, title: "One", albumTitle: "Album", albumArtist: "Artist"),
            rootID: rootID
        )
        let secondID = try database.save(
            track: track(for: secondURL, title: "Two", albumTitle: "Album", albumArtist: "Artist"),
            rootID: rootID
        )
        try commitAllPendingTracks(in: database)
        let originalMembers = try [firstID, secondID].map { id in
            let data = try XCTUnwrap(database.replayGainData(trackID: id))
            return ReplayGainAlbumMember(trackID: id, fingerprint: data.fingerprint, trackRevision: data.trackRevision)
        }

        let thirdURL = try makeAudioFile(in: root, name: "three.flac")
        _ = try database.save(
            track: track(for: thirdURL, title: "Three", albumTitle: "Album", albumArtist: "Artist"),
            rootID: rootID
        )

        XCTAssertNil(
            try database.commitReplayGainAlbumResult(
                albumKey: AlbumKey(title: "Album", owner: "Artist"),
                members: originalMembers,
                values: readyAlbumValues
            )
        )
        XCTAssertNil(try database.replayGainData(trackID: firstID)?.album)
        XCTAssertNil(try database.replayGainData(trackID: secondID)?.album)

        try commitAllPendingTracks(in: database)
        let allTracks = try database.tracks(album: AlbumKey(title: "Album", owner: "Artist"))
        let currentMembers = try allTracks.map { track -> ReplayGainAlbumMember in
            let id = try XCTUnwrap(track.id)
            let data = try XCTUnwrap(database.replayGainData(trackID: id))
            return ReplayGainAlbumMember(trackID: id, fingerprint: data.fingerprint, trackRevision: data.trackRevision)
        }
        let generation = try XCTUnwrap(
            database.commitReplayGainAlbumResult(
                albumKey: AlbumKey(title: "Album", owner: "Artist"),
                members: currentMembers,
                values: readyAlbumValues
            )
        )
        let stored = try allTracks.map { try XCTUnwrap(database.replayGainData(trackID: XCTUnwrap($0.id))) }
        XCTAssertEqual(Set(stored.compactMap(\.albumGeneration)), [generation])
        XCTAssertTrue(stored.allSatisfy { $0.album == readyAlbumValues })
    }

    func testAlbumCommitRejectsRequeuedTrackRevision() throws {
        let root = try makeRoot()
        let firstURL = try makeAudioFile(in: root, name: "one.flac")
        let secondURL = try makeAudioFile(in: root, name: "two.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let firstID = try database.save(
            track: track(for: firstURL, title: "One", albumTitle: "Album", albumArtist: "Artist"),
            rootID: rootID
        )
        let secondID = try database.save(
            track: track(for: secondURL, title: "Two", albumTitle: "Album", albumArtist: "Artist"),
            rootID: rootID
        )
        try commitAllPendingTracks(in: database)
        let staleMembers = try albumMembers(trackIDs: [firstID, secondID], database: database)

        try database.requeueReplayGain(trackIDs: [firstID])

        XCTAssertNil(
            try database.commitReplayGainAlbumResult(
                albumKey: AlbumKey(title: "Album", owner: "Artist"),
                members: staleMembers,
                values: readyAlbumValues
            )
        )
        XCTAssertNil(try database.replayGainData(trackID: firstID)?.album)
        XCTAssertNil(try database.replayGainData(trackID: secondID)?.album)
    }

    func testInvalidatingMultipleChangedAlbumMembersClearsAllTrackValues() throws {
        let root = try makeRoot()
        let firstURL = try makeAudioFile(in: root, name: "one.flac")
        let secondURL = try makeAudioFile(in: root, name: "two.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let firstID = try database.save(
            track: track(for: firstURL, title: "One", albumTitle: "Album", albumArtist: "Artist"),
            rootID: rootID
        )
        let secondID = try database.save(
            track: track(for: secondURL, title: "Two", albumTitle: "Album", albumArtist: "Artist"),
            rootID: rootID
        )
        try commitAllPendingTracks(in: database)
        let members = try albumMembers(trackIDs: [firstID, secondID], database: database)
        XCTAssertNotNil(
            try database.commitReplayGainAlbumResult(
                albumKey: AlbumKey(title: "Album", owner: "Artist"),
                members: members,
                values: readyAlbumValues
            )
        )

        try Data([4]).append(to: firstURL)
        try Data([5]).append(to: secondURL)
        let firstCurrent = ReplayGainFileFingerprint.current(path: firstURL.path)
        let secondCurrent = ReplayGainFileFingerprint.current(path: secondURL.path)

        XCTAssertTrue(try database.invalidateReplayGainForFileChange(
            trackID: firstID,
            expectedFingerprint: members[0].fingerprint,
            currentFingerprint: firstCurrent,
            claimToken: nil,
            ignoringCancellation: true
        ))
        XCTAssertTrue(try database.invalidateReplayGainForFileChange(
            trackID: secondID,
            expectedFingerprint: members[1].fingerprint,
            currentFingerprint: secondCurrent,
            claimToken: nil,
            ignoringCancellation: true
        ))

        for trackID in [firstID, secondID] {
            let data = try XCTUnwrap(database.replayGainData(trackID: trackID))
            XCTAssertEqual(data.state, .pending)
            XCTAssertNil(data.track)
            XCTAssertNil(data.album)
        }
    }

    func testPruningAlbumMemberInvalidatesSurvivingAlbumResult() throws {
        let root = try makeRoot()
        let firstURL = try makeAudioFile(in: root, name: "one.flac")
        let secondURL = try makeAudioFile(in: root, name: "two.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let firstID = try database.save(
            track: track(for: firstURL, title: "One", albumTitle: "Album", albumArtist: "Artist"),
            rootID: rootID
        )
        let secondID = try database.save(
            track: track(for: secondURL, title: "Two", albumTitle: "Album", albumArtist: "Artist"),
            rootID: rootID
        )
        try commitAllPendingTracks(in: database)
        let members = try albumMembers(trackIDs: [firstID, secondID], database: database)
        XCTAssertNotNil(
            try database.commitReplayGainAlbumResult(
                albumKey: AlbumKey(title: "Album", owner: "Artist"),
                members: members,
                values: readyAlbumValues
            )
        )

        try FileManager.default.removeItem(at: secondURL)
        XCTAssertEqual(try database.pruneMissingTracks(rootPath: root.path, existingPaths: [firstURL.path]), 1)

        XCTAssertNil(try database.replayGainData(trackID: firstID)?.album)
        XCTAssertEqual(try database.replayGainData(trackID: firstID)?.state, .pending)
        XCTAssertNil(try database.replayGainData(trackID: secondID))
    }

    func testRemovingAlbumMemberRequeuesAlbumOnlyFailure() throws {
        let root = try makeRoot()
        let firstURL = try makeAudioFile(in: root, name: "one.flac")
        let secondURL = try makeAudioFile(in: root, name: "two.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let firstID = try database.save(
            track: track(for: firstURL, title: "One", albumTitle: "Album", albumArtist: "Artist"),
            rootID: rootID
        )
        let secondID = try database.save(
            track: track(for: secondURL, title: "Two", albumTitle: "Album", albumArtist: "Artist"),
            rootID: rootID
        )
        try commitAllPendingTracks(in: database)
        let failedAlbum = try XCTUnwrap(database.nextReplayGainAlbumAnalysisItem())
        XCTAssertTrue(
            try database.recordReplayGainAlbumFailure(
                item: failedAlbum,
                reason: String(repeating: "x", count: 500)
            )
        )

        try FileManager.default.removeItem(at: secondURL)
        try database.reconcile(
            rootPath: root.path,
            tracks: [track(for: firstURL, title: "One", albumTitle: "Album", albumArtist: "Artist")],
            lyricFiles: []
        )

        let invalidated = try XCTUnwrap(database.replayGainData(trackID: firstID))
        XCTAssertEqual(invalidated.state, .pending)
        XCTAssertEqual(invalidated.track, readyTrackValues)
        XCTAssertNil(invalidated.album)
        XCTAssertNil(invalidated.errorReason)
        XCTAssertNil(invalidated.errorAt)
        XCTAssertNil(try database.replayGainData(trackID: secondID))

        let retryTrack = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        XCTAssertEqual(retryTrack.trackID, firstID)
        XCTAssertEqual(retryTrack.cachedTrackValues, readyTrackValues)
        XCTAssertTrue(
            try database.commitReplayGainTrackResult(
                trackID: firstID,
                fingerprint: retryTrack.fingerprint,
                claimToken: retryTrack.claimToken,
                values: readyTrackValues
            )
        )
        let retryAlbum = try XCTUnwrap(database.nextReplayGainAlbumAnalysisItem())
        XCTAssertEqual(retryAlbum.allPaths, [firstURL.path])
        XCTAssertNotNil(
            try database.commitReplayGainAlbumResult(
                albumKey: AlbumKey(title: "Album", owner: "Artist"),
                members: retryAlbum.members,
                values: readyAlbumValues
            )
        )

        let recomputed = try XCTUnwrap(database.replayGainData(trackID: firstID))
        XCTAssertEqual(recomputed.state, .ready)
        XCTAssertEqual(recomputed.album, readyAlbumValues)
        XCTAssertNil(recomputed.errorReason)
    }

    func testRemovingAlbumMemberRetriesAlbumWhilePreservingTrackFailure() throws {
        let root = try makeRoot()
        let firstURL = try makeAudioFile(in: root, name: "one.flac")
        let secondURL = try makeAudioFile(in: root, name: "two.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let firstID = try database.save(
            track: track(for: firstURL, title: "One", albumTitle: "Album", albumArtist: "Artist"),
            rootID: rootID
        )
        let secondID = try database.save(
            track: track(for: secondURL, title: "Two", albumTitle: "Album", albumArtist: "Artist"),
            rootID: rootID
        )
        let failedTrack = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        XCTAssertEqual(failedTrack.trackID, firstID)
        XCTAssertTrue(
            try database.recordReplayGainFailure(
                trackID: firstID,
                fingerprint: failedTrack.fingerprint,
                claimToken: failedTrack.claimToken,
                reason: "decode failed"
            )
        )
        let readyTrack = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        XCTAssertEqual(readyTrack.trackID, secondID)
        XCTAssertTrue(
            try database.commitReplayGainTrackResult(
                trackID: secondID,
                fingerprint: readyTrack.fingerprint,
                claimToken: readyTrack.claimToken,
                values: readyTrackValues
            )
        )
        let failedAlbum = try XCTUnwrap(database.nextReplayGainAlbumAnalysisItem())
        XCTAssertTrue(
            try database.recordReplayGainAlbumFailure(
                item: failedAlbum,
                reason: String(repeating: "x", count: 500)
            )
        )

        try assertRemovingAlbumMemberResult(
            in: database,
            firstID: firstID,
            firstURL: firstURL,
            secondURL: secondURL
        )
    }

    func testStaleTrackFailureIsRejectedAndRequeuedWithCurrentFingerprint() throws {
        let root = try makeRoot()
        let audio = try makeAudioFile(in: root, name: "one.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let trackID = try database.save(track: track(for: audio), rootID: rootID)
        let pending = try XCTUnwrap(database.claimNextPendingReplayGainItem())

        try Data([4]).append(to: audio)

        XCTAssertFalse(
            try database.recordReplayGainFailure(
                trackID: trackID,
                fingerprint: pending.fingerprint,
                claimToken: pending.claimToken,
                reason: "decode failed"
            )
        )
        let refreshed = try XCTUnwrap(database.replayGainData(trackID: trackID))
        XCTAssertEqual(refreshed.state, .pending)
        XCTAssertNil(refreshed.track)
        XCTAssertNil(refreshed.errorReason)
        XCTAssertNil(refreshed.errorAt)
        XCTAssertEqual(refreshed.fingerprint.fileSize, Int64(try Data(contentsOf: audio).count))
        XCTAssertTrue(try database.replayGainFailures().isEmpty)

        let retry = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        XCTAssertEqual(retry.trackID, trackID)
        XCTAssertEqual(retry.fingerprint, refreshed.fingerprint)
    }

    func testFailureRequiresManualRequeueAndIsRecordedOnce() throws {
        let root = try makeRoot()
        let audio = try makeAudioFile(in: root, name: "one.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let trackID = try database.save(track: track(for: audio), rootID: rootID)
        let pending = try XCTUnwrap(database.claimNextPendingReplayGainItem())

        XCTAssertTrue(
            try database.recordReplayGainFailure(
                trackID: trackID,
                fingerprint: pending.fingerprint,
                claimToken: pending.claimToken,
                reason: "decode failed"
            )
        )
        XCTAssertFalse(
            try database.recordReplayGainFailure(
                trackID: trackID,
                fingerprint: pending.fingerprint,
                claimToken: pending.claimToken,
                reason: "duplicate"
            )
        )
        XCTAssertNil(try database.claimNextPendingReplayGainItem())
        XCTAssertEqual(try database.replayGainFailures().map(\.reason), ["decode failed"])

        try database.requeueReplayGain(trackIDs: [trackID])
        XCTAssertNotNil(try database.claimNextPendingReplayGainItem())
    }

    func testReleasedAndInterruptedClaimsReturnToPending() throws {
        let root = try makeRoot()
        let firstURL = try makeAudioFile(in: root, name: "one.flac")
        let secondURL = try makeAudioFile(in: root, name: "two.flac")
        let databaseURL = root.appending(path: "Library.sqlite")
        var interruptedTrackID: Int64 = 0

        do {
            let database = try LibraryDatabase(path: databaseURL.path)
            let rootID = try database.addRoot(path: root.path)
            let releasedTrackID = try database.save(track: track(for: firstURL), rootID: rootID)
            interruptedTrackID = try database.save(track: track(for: secondURL, title: "Two"), rootID: rootID)
            let released = try XCTUnwrap(database.claimNextPendingReplayGainItem())
            XCTAssertEqual(released.trackID, releasedTrackID)
            XCTAssertTrue(
                try database.releaseReplayGainClaim(
                    trackID: released.trackID,
                    fingerprint: released.fingerprint,
                    claimToken: released.claimToken
                )
            )
            let reclaimed = try XCTUnwrap(database.claimNextPendingReplayGainItem())
            XCTAssertEqual(reclaimed.trackID, releasedTrackID)
            try database.recordReplayGainFailure(
                trackID: releasedTrackID,
                fingerprint: reclaimed.fingerprint,
                claimToken: reclaimed.claimToken,
                reason: "skip first"
            )
            XCTAssertEqual(try database.claimNextPendingReplayGainItem()?.trackID, interruptedTrackID)
        }

        let reopened = try LibraryDatabase(path: databaseURL.path)
        XCTAssertEqual(try reopened.claimNextPendingReplayGainItem()?.trackID, interruptedTrackID)
    }
    private func assertRemovingAlbumMemberResult(
        in database: LibraryDatabase,
        firstID: Int64,
        firstURL: URL,
        secondURL: URL
    ) throws {
        try FileManager.default.removeItem(at: secondURL)
        try database.reconcile(
            rootPath: firstURL.deletingLastPathComponent().path,
            tracks: [track(for: firstURL, title: "One", albumTitle: "Album", albumArtist: "Artist")],
            lyricFiles: []
        )

        let invalidated = try XCTUnwrap(database.replayGainData(trackID: firstID))
        XCTAssertEqual(invalidated.state, .failed)
        XCTAssertNil(invalidated.track)
        XCTAssertNil(invalidated.album)
        XCTAssertEqual(invalidated.errorReason, "decode failed")
        XCTAssertNotNil(invalidated.errorAt)
        let retryAlbum = try XCTUnwrap(database.nextReplayGainAlbumAnalysisItem())
        XCTAssertEqual(retryAlbum.allPaths, [firstURL.path])
        XCTAssertTrue(retryAlbum.availablePaths.isEmpty)
        XCTAssertNotNil(
            try database.commitReplayGainAlbumResult(
                albumKey: AlbumKey(title: "Album", owner: "Artist"),
                members: retryAlbum.members,
                values: readyAlbumValues
            )
        )

        let recomputed = try XCTUnwrap(database.replayGainData(trackID: firstID))
        XCTAssertEqual(recomputed.state, .failed)
        XCTAssertNil(recomputed.track)
        XCTAssertEqual(recomputed.album, readyAlbumValues)
        XCTAssertEqual(recomputed.errorReason, "decode failed")
        XCTAssertNotNil(recomputed.errorAt)
    }
}
