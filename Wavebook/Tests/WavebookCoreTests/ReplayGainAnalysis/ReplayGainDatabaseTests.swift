import Foundation
import GRDB
@testable import WavebookCore
import XCTest

extension ReplayGainDatabaseTests {
    func testNewTrackIsPendingAndModeDefaultsOff() throws {
        let root = try makeRoot()
        let audio = try makeAudioFile(in: root, name: "one.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        _ = try database.save(track: track(for: audio), rootID: rootID)

        XCTAssertEqual(try database.replayGainMode(), .off)
        XCTAssertEqual(try database.replayGainAnalysisFileConcurrency(), 1)
        XCTAssertEqual(try database.replayGainStatusCounts(), ReplayGainAnalysisStatusCounts(pending: 1))
        XCTAssertEqual(
            try database.replayGainAnalysisProgress(),
            ReplayGainAnalysisProgress(total: 1, trackCompleted: 0, albumCompleted: 0)
        )

        try database.saveReplayGainMode(.album)
        XCTAssertEqual(try database.replayGainMode(), .album)
        try database.saveReplayGainAnalysisFileConcurrency(4)
        XCTAssertEqual(try database.replayGainAnalysisFileConcurrency(), 4)
        try database.saveReplayGainAnalysisFileConcurrency(99)
        XCTAssertEqual(try database.replayGainAnalysisFileConcurrency(), 15)
        try database.saveReplayGainAnalysisFileConcurrency(0)
        XCTAssertEqual(try database.replayGainAnalysisFileConcurrency(), 1)
    }

    func testContentFingerprintChangesInvalidateButUnchangedContentPreservesResult() throws {
        let root = try makeRoot()
        let audio = try makeAudioFile(in: root, name: "one.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let trackID = try database.save(track: track(for: audio), rootID: rootID)
        let first = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        XCTAssertTrue(
            try database.commitReplayGainTrackResult(
                trackID: trackID,
                fingerprint: first.fingerprint,
                claimToken: first.claimToken,
                values: readyTrackValues
            )
        )

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: audio.path
        )
        _ = try database.save(track: track(for: audio), rootID: rootID)
        XCTAssertEqual(try database.replayGainData(trackID: trackID)?.state, .ready)
        XCTAssertEqual(try database.replayGainData(trackID: trackID)?.track, readyTrackValues)

        try Data([4]).append(to: audio)
        _ = try database.save(track: track(for: audio), rootID: rootID)
        XCTAssertEqual(try database.replayGainData(trackID: trackID)?.state, .pending)
        XCTAssertNil(try database.replayGainData(trackID: trackID)?.track)

        let second = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        XCTAssertTrue(
            try database.commitReplayGainTrackResult(
                trackID: trackID,
                fingerprint: second.fingerprint,
                claimToken: second.claimToken,
                values: readyTrackValues
            )
        )
    }

    func testLargeFileHashSurvivesRescanAndDetectsChanges() throws {
        let root = try makeRoot()
        let audio = root.appending(path: "large.flac")
        try Data(
            repeating: 7,
            count: 1 * 1_024 * 1_024 + 1
        ).write(to: audio)
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let trackID = try database.save(track: track(for: audio), rootID: rootID)
        let pending = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        XCTAssertNotNil(pending.fingerprint.contentFingerprint)
        XCTAssertTrue(try database.commitReplayGainTrackResult(
            trackID: trackID,
            fingerprint: pending.fingerprint,
            claimToken: pending.claimToken,
            values: readyTrackValues
        ))

        _ = try database.save(track: track(for: audio), rootID: rootID)

        let data = try XCTUnwrap(database.replayGainData(trackID: trackID))
        XCTAssertEqual(data.state, .ready)
        XCTAssertEqual(data.track, readyTrackValues)

        try Data([8]).append(to: audio)
        _ = try database.save(track: track(for: audio), rootID: rootID)

        let changedData = try XCTUnwrap(database.replayGainData(trackID: trackID))
        XCTAssertEqual(changedData.state, .pending)
        XCTAssertNil(changedData.track)
        XCTAssertNotEqual(changedData.fingerprint.contentFingerprint, data.fingerprint.contentFingerprint)
    }

    func testEqualSizeReplacementWithRestoredMetadataInvalidatesReplayGain() throws {
        let root = try makeRoot()
        let audio = try makeAudioFile(in: root, name: "one.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let trackID = try database.save(track: track(for: audio), rootID: rootID)
        let pending = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        let originalValues = try audio.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let originalDate = try XCTUnwrap(originalValues.contentModificationDate)

        XCTAssertTrue(try database.commitReplayGainTrackResult(
            trackID: trackID,
            fingerprint: pending.fingerprint,
            claimToken: pending.claimToken,
            values: readyTrackValues
        ))
        let oldData = try XCTUnwrap(database.replayGainData(trackID: trackID))

        try Data([4, 5, 6]).write(to: audio)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: audio.path)
        let restoredValues = try audio.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        XCTAssertEqual(restoredValues.contentModificationDate, originalValues.contentModificationDate)
        XCTAssertEqual(restoredValues.fileSize, originalValues.fileSize)

        _ = try database.save(track: track(for: audio), rootID: rootID)

        let updatedData = try XCTUnwrap(database.replayGainData(trackID: trackID))
        XCTAssertEqual(updatedData.state, .pending)
        XCTAssertNil(updatedData.track)
        XCTAssertNotEqual(updatedData.fingerprint, oldData.fingerprint)
        XCTAssertNotEqual(updatedData.fingerprint.contentFingerprint, oldData.fingerprint.contentFingerprint)
    }

    func testRuntimeSameMetadataReplacementCannotCommitStaleTrackResult() throws {
        let root = try makeRoot()
        let audio = try makeAudioFile(in: root, name: "one.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let trackID = try database.save(track: track(for: audio), rootID: rootID)
        let pending = try XCTUnwrap(database.claimNextPendingReplayGainItem())
        let originalValues = try audio.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let originalDate = try XCTUnwrap(originalValues.contentModificationDate)

        try Data([4, 5, 6]).write(to: audio)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: audio.path)
        let restoredValues = try audio.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        XCTAssertEqual(restoredValues.contentModificationDate, originalValues.contentModificationDate)
        XCTAssertEqual(restoredValues.fileSize, originalValues.fileSize)

        XCTAssertFalse(try database.commitReplayGainTrackResult(
            trackID: trackID,
            fingerprint: pending.fingerprint,
            claimToken: pending.claimToken,
            values: readyTrackValues
        ))
        XCTAssertEqual(try database.replayGainData(trackID: trackID)?.state, .pending)
        XCTAssertNil(try database.replayGainData(trackID: trackID)?.track)
    }

    func testChangedFailedTrackWithoutValuesIsRequeued() throws {
        let root = try makeRoot()
        let audio = try makeAudioFile(in: root, name: "one.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let trackID = try database.save(track: track(for: audio), rootID: rootID)
        let pending = try XCTUnwrap(database.claimNextPendingReplayGainItem())

        XCTAssertTrue(try database.recordReplayGainFailure(
            trackID: trackID,
            fingerprint: pending.fingerprint,
            claimToken: pending.claimToken,
            reason: "decode failed"
        ))
        XCTAssertEqual(try database.replayGainData(trackID: trackID)?.state, .failed)
        XCTAssertNil(try database.replayGainData(trackID: trackID)?.track)

        let originalValues = try audio.resourceValues(forKeys: [.contentModificationDateKey])
        try Data([7, 8, 9]).write(to: audio)
        if let originalDate = originalValues.contentModificationDate {
            try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: audio.path)
        }
        let currentFingerprint = ReplayGainFileFingerprint.current(path: audio.path)
        let reconciled = try database.reconcileFailedCandidates(rootPath: root.path, paths: [audio.path])

        XCTAssertTrue(reconciled.contains(audio.path))
        XCTAssertEqual(try database.replayGainData(trackID: trackID)?.state, .pending)
        XCTAssertEqual(try database.replayGainData(trackID: trackID)?.fingerprint, currentFingerprint)
    }

    func testStaleTrackResultCannotOverwriteChangedFingerprint() throws {
        let root = try makeRoot()
        let audio = try makeAudioFile(in: root, name: "one.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let trackID = try database.save(track: track(for: audio), rootID: rootID)
        let pending = try XCTUnwrap(database.claimNextPendingReplayGainItem())

        try Data([4]).append(to: audio)
        _ = try database.save(track: track(for: audio), rootID: rootID)

         XCTAssertFalse(
             try database.commitReplayGainTrackResult(
                 trackID: trackID,
                 fingerprint: pending.fingerprint,
                 claimToken: pending.claimToken,
                 values: readyTrackValues
             )
         )
        XCTAssertEqual(try database.replayGainData(trackID: trackID)?.state, .pending)
        XCTAssertNil(try database.replayGainData(trackID: trackID)?.track)
    }

    func testReleasedClaimCannotCommitAfterTrackIsReclaimed() throws {
        let root = try makeRoot()
        let audio = try makeAudioFile(in: root, name: "one.flac")
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let trackID = try database.save(track: track(for: audio), rootID: rootID)
        let first = try XCTUnwrap(database.claimNextPendingReplayGainItem())
         XCTAssertTrue(
             try database.releaseReplayGainClaim(
                 trackID: trackID,
                 fingerprint: first.fingerprint,
                 claimToken: first.claimToken
             )
         )
        let second = try XCTUnwrap(database.claimNextPendingReplayGainItem())

         XCTAssertFalse(
             try database.commitReplayGainTrackResult(
                 trackID: trackID,
                 fingerprint: first.fingerprint,
                 claimToken: first.claimToken,
                 values: readyTrackValues
             )
         )
         XCTAssertTrue(
             try database.commitReplayGainTrackResult(
                 trackID: trackID,
                 fingerprint: second.fingerprint,
                 claimToken: second.claimToken,
                 values: readyTrackValues
             )
         )
    }

    func testCompletedTrackResultPersistsAcrossReopen() throws {
        let root = try makeRoot()
        let audio = try makeAudioFile(in: root, name: "one.flac")
        let databaseURL = root.appending(path: "Library.sqlite")
        var trackID: Int64 = 0

        do {
            let database = try LibraryDatabase(path: databaseURL.path)
            let rootID = try database.addRoot(path: root.path)
            trackID = try database.save(track: track(for: audio), rootID: rootID)
            let pending = try XCTUnwrap(database.claimNextPendingReplayGainItem())
             XCTAssertTrue(
                 try database.commitReplayGainTrackResult(
                     trackID: trackID,
                     fingerprint: pending.fingerprint,
                     claimToken: pending.claimToken,
                     values: readyTrackValues
                 )
             )
        }

        let reopened = try LibraryDatabase(path: databaseURL.path)
        XCTAssertEqual(try reopened.replayGainData(trackID: trackID)?.state, .ready)
        XCTAssertEqual(try reopened.replayGainData(trackID: trackID)?.track, readyTrackValues)
    }
}
