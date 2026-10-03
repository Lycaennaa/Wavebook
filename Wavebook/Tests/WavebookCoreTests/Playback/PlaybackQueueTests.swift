@testable import WavebookCore
import XCTest

final class PlaybackQueueTests: XCTestCase {
    func testCandidatesDoNotCommitQueuePosition() {
        let tracks = [track(1), track(2)]
        var queue = PlaybackQueue(items: tracks)

        XCTAssertEqual(queue.nextIndex, 0)
        XCTAssertEqual(queue.track(at: 0), tracks[0])
        XCTAssertNil(queue.currentIndex)
        _ = queue.play(at: 0)
        XCTAssertEqual(queue.previousIndex, nil)
        XCTAssertEqual(queue.nextIndex, 1)
        XCTAssertEqual(queue.currentIndex, 0)
    }

    func testFailedReplacementSkipsCommittedOccurrenceWithoutChangingQueueEntries() {
        var queue = PlaybackQueue(items: [track(1), track(2)])
        let entries = queue.entries
        let current = entries[0]
        let replacement = entries[1]

        XCTAssertEqual(queue.play(current), current.track)
        queue.setRepeatMode(.one)
        queue.markCurrentTrackPlaybackFailed()

        XCTAssertEqual(queue.currentEntry?.id, current.id)
        XCTAssertEqual(queue.playbackIndex, queue.entryIndex(of: replacement))
        XCTAssertEqual(queue.entry(at: queue.playbackIndex ?? -1)?.id, replacement.id)
        XCTAssertEqual(queue.entries.map(\.id), entries.map(\.id))
    }
     func testFailedReplacementKeepsCurrentOccurrenceAndRetriesAttemptedOccurrence() throws {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3)])
        let entries = queue.entries
        let current = entries[0]
        let replacement = entries[1]

        XCTAssertEqual(queue.play(current), current.track)
        queue.setRepeatMode(.one)
        queue.markPlaybackFailed(for: replacement)

        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(queue.currentEntry?.id, current.id)
        XCTAssertEqual(queue.currentTrack?.title, current.track.title)
        XCTAssertEqual(queue.nextIndex, 1)
        XCTAssertNil(queue.previousIndex)
        XCTAssertEqual(queue.playbackIndex, 1)
        XCTAssertEqual(queue.entry(at: queue.playbackIndex ?? -1)?.id, replacement.id)
        XCTAssertEqual(queue.entries.map(\.id), entries.map(\.id))

         let retryIndex = try XCTUnwrap(queue.playbackIndex)
        XCTAssertEqual(queue.play(at: retryIndex), replacement.track)
        XCTAssertEqual(queue.currentEntry?.id, replacement.id)
        XCTAssertEqual(queue.currentTrack?.title, replacement.track.title)
        XCTAssertEqual(queue.playbackIndex, retryIndex)
    }

    func testFailedOnlyEntryDoesNotRepeatWithRepeatAll() {
        var queue = PlaybackQueue(items: [track(1)])
        queue.setRepeatMode(.all)
        _ = queue.play(at: 0)

        queue.markCurrentTrackPlaybackFailed()

        XCTAssertTrue(queue.isAtEnd)
        XCTAssertNil(queue.playbackIndex)
    }

    func testAppendRemoveAndClear() {
        var queue = PlaybackQueue()
        queue.append(track(1))
        queue.append(track(2))

        XCTAssertEqual(queue.items.map(\.title), ["Track 1", "Track 2"])
        XCTAssertNil(queue.remove(at: 2))
        XCTAssertEqual(queue.remove(at: 0)?.title, "Track 1")
        XCTAssertEqual(queue.items.map(\.title), ["Track 2"])

        queue.clear()
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertNil(queue.currentIndex)
    }
    func testQueueCapsRetainedEntries() {
        let tracks = Array(repeating: track(1), count: PlaybackQueue.maximumEntryCount + 1)
        var queue = PlaybackQueue(items: tracks)

        XCTAssertEqual(queue.entries.count, PlaybackQueue.maximumEntryCount)
        queue.append(track(2))
        XCTAssertEqual(queue.entries.count, PlaybackQueue.maximumEntryCount)
    }

    func testRemoveEntriesByIDPreservesCurrentStateAndReportsRemoval() {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3), track(4)], currentIndex: 2)
        let entries = queue.entries

        let removal = queue.removeEntries(withIDs: [entries[0].id, entries[2].id])

        XCTAssertEqual(removal.removedEntries.map(\.id), [entries[0].id, entries[2].id])
        XCTAssertTrue(removal.removedCurrentEntry)
        XCTAssertEqual(queue.items.map(\.title), ["Track 2", "Track 4"])
        XCTAssertNil(queue.currentIndex)
    }

    func testRemoveEntriesByIDPreservesShuffledOrder() {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3), track(4)])
        queue.setShuffleEnabled(true)
        let queuedEntries = queue.queuedEntries
        let removalIDs = [queuedEntries[0].id, queuedEntries[2].id]
        let expectedIDs = queuedEntries
            .filter { !Set(removalIDs).contains($0.id) }
            .map(\.id)

        let removal = queue.removeEntries(withIDs: removalIDs)

        XCTAssertEqual(removal.removedEntries.map(\.id), removalIDs)
        XCTAssertFalse(removal.removedCurrentEntry)
        XCTAssertEqual(queue.queuedEntries.map(\.id), expectedIDs)
    }

    func testAppendContentsPreservesCurrentTrack() {
        var queue = PlaybackQueue(items: [track(1), track(2)], currentIndex: 0)

        queue.append(contentsOf: [track(3), track(4)])

        XCTAssertEqual(queue.items.map(\.title), ["Track 1", "Track 2", "Track 3", "Track 4"])
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(queue.currentTrack?.title, "Track 1")
    }

    func testSourceStaysWithQueueEntriesAndStableIDs() {
        let playlistSource = ListeningPlaybackSource(
            kind: .playlist,
            persistentID: 42,
            sourceName: "Road Trip"
        )
        var queue = PlaybackQueue()
        queue.replace(with: [track(1), track(2)], source: playlistSource)
        let originalIDs = queue.entries.map(\.id)

        XCTAssertEqual(queue.entries.map(\.source), [playlistSource, playlistSource])

        queue.updateFavoriteState(trackID: 1, isFavorite: true)
        XCTAssertEqual(queue.entries.map(\.id), originalIDs)
        XCTAssertEqual(queue.entries.map(\.source), [playlistSource, playlistSource])

        queue.insertNext(
            [track(3)],
            source: ListeningPlaybackSource(kind: .library)
        )
        XCTAssertEqual(queue.entries[0].source, ListeningPlaybackSource(kind: .library))
        XCTAssertEqual(queue.entries[1].source, playlistSource)
    }

    func testPlaybackTrackContextKeepsSourceWithCurrentTrack() {
        let source = ListeningPlaybackSource(
            kind: .playlist,
            persistentID: 42,
            sourceName: "Road Trip"
        )
        let context = PlaybackTrackContext(track: track(1), source: source)

        XCTAssertEqual(context.track.title, "Track 1")
        XCTAssertEqual(context.source, source)
    }

    func testInsertNextPreservesSelectionOrderAndCurrentTrack() {
        var pendingQueue = PlaybackQueue(items: [track(3), track(4)])
        pendingQueue.insertNext([track(1), track(2)])
        XCTAssertEqual(pendingQueue.items.map(\.title), ["Track 1", "Track 2", "Track 3", "Track 4"])
        XCTAssertNil(pendingQueue.currentIndex)

        var activeQueue = PlaybackQueue(items: [track(1), track(4)], currentIndex: 0)
        activeQueue.insertNext([track(2), track(3)])
        XCTAssertEqual(activeQueue.items.map(\.title), ["Track 1", "Track 2", "Track 3", "Track 4"])
        XCTAssertEqual(activeQueue.currentIndex, 0)
        XCTAssertEqual(activeQueue.nextIndex, 1)
        XCTAssertEqual(activeQueue.currentTrack?.title, "Track 1")

        activeQueue.insertNext([])
        XCTAssertEqual(activeQueue.items.map(\.title), ["Track 1", "Track 2", "Track 3", "Track 4"])
    }

    func testPlayAndRemoveKeepCurrentTrackStable() {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3)])
        XCTAssertEqual(queue.play(at: 1)?.title, "Track 2")

        queue.remove(at: 0)
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(queue.currentTrack?.title, "Track 2")

        queue.remove(at: 1)
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(queue.currentTrack?.title, "Track 2")

        queue.remove(at: 0)
        XCTAssertNil(queue.currentIndex)
        XCTAssertNil(queue.currentTrack)
    }

    func testMoveKeepsCurrentTrackStable() {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3), track(4)])
        _ = queue.play(at: 2)

        XCTAssertTrue(queue.move(from: 0, to: 3))
        XCTAssertEqual(queue.items.map(\.title), ["Track 2", "Track 3", "Track 4", "Track 1"])
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertEqual(queue.currentTrack?.title, "Track 3")

        XCTAssertTrue(queue.move(from: 1, to: 3))
        XCTAssertEqual(queue.items.map(\.title), ["Track 2", "Track 4", "Track 1", "Track 3"])
        XCTAssertEqual(queue.currentIndex, 3)
        XCTAssertEqual(queue.currentTrack?.title, "Track 3")

        XCTAssertFalse(queue.move(from: 9, to: 0))
    }

    func testMoveAfterCurrentToBeforeCurrentKeepsCurrentTrackStable() {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3), track(4)])
        _ = queue.play(at: 1)

        XCTAssertTrue(queue.move(from: 3, to: 0))

        XCTAssertEqual(queue.items.map(\.title), ["Track 4", "Track 1", "Track 2", "Track 3"])
        XCTAssertEqual(queue.currentIndex, 2)
        XCTAssertEqual(queue.currentTrack?.title, "Track 2")
    }

    func testNextAndPreviousAdvanceThroughQueue() {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3)])

        XCTAssertTrue(queue.canAdvanceToNext)
        XCTAssertFalse(queue.canReturnToPrevious)
        XCTAssertEqual(queue.next()?.title, "Track 1")
        XCTAssertTrue(queue.canAdvanceToNext)
        XCTAssertFalse(queue.canReturnToPrevious)
        XCTAssertEqual(queue.next()?.title, "Track 2")
        XCTAssertTrue(queue.canAdvanceToNext)
        XCTAssertTrue(queue.canReturnToPrevious)
        XCTAssertEqual(queue.next()?.title, "Track 3")
        XCTAssertFalse(queue.canAdvanceToNext)
        XCTAssertTrue(queue.canReturnToPrevious)
        XCTAssertEqual(queue.previous()?.title, "Track 2")
        XCTAssertEqual(queue.previous()?.title, "Track 1")
        XCTAssertNil(queue.previous())

        XCTAssertEqual(queue.currentTrack?.title, "Track 1")
    }

    func testFinishedQueueDoesNotReplayLastTrack() {
        var queue = PlaybackQueue(items: [track(1)])
        _ = queue.play(at: 0)

        queue.markCurrentTrackFinished()

        XCTAssertTrue(queue.isAtEnd)
        XCTAssertNil(queue.playbackIndex)
        XCTAssertEqual(queue.currentTrack?.title, "Track 1")
    }

    func testEmptyQueueCanBeMarkedAtEnd() {
        var queue = PlaybackQueue()

        queue.markCurrentTrackFinished()

        XCTAssertTrue(queue.isAtEnd)
        XCTAssertNil(queue.playbackIndex)
    }

    func testFinishedTrackAdvancesToTracksAddedLater() {
        var queue = PlaybackQueue(items: [track(1)])
        _ = queue.play(at: 0)
        queue.markCurrentTrackFinished()

        queue.append(track(2))

        XCTAssertFalse(queue.isAtEnd)
        XCTAssertEqual(queue.playbackIndex, 1)
        XCTAssertEqual(queue.next()?.title, "Track 2")
        XCTAssertFalse(queue.isAtEnd)
        XCTAssertEqual(queue.playbackIndex, 1)
    }

    func testShufflePlaysEveryTrackOnceAndTracksHistory() {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3), track(4)])
        queue.setShuffleEnabled(true)

        var played: [String] = []
        while let next = queue.next() {
            played.append(next.title)
        }

        XCTAssertEqual(played.count, 4)
        XCTAssertEqual(Set(played), Set(["Track 1", "Track 2", "Track 3", "Track 4"]))
        XCTAssertEqual(queue.previous()?.title, played[2])
    }
}

extension PlaybackQueueTests {

     func testQueuedItemsFollowShuffledPlaybackOrder() throws {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3), track(4)])
        queue.setShuffleEnabled(true)

        XCTAssertEqual(Set(queue.queuedItems.map(\.title)), Set(["Track 1", "Track 2", "Track 3", "Track 4"]))
        for (queueIndex, queuedTrack) in queue.queuedItems.enumerated() {
             let itemIndex = try XCTUnwrap(queue.itemIndex(atQueueIndex: queueIndex))
            XCTAssertEqual(queue.track(at: itemIndex), queuedTrack)
        }
    }

    func testMovingShuffledQueuedItemChangesPlaybackOrder() {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3)])
        queue.setShuffleEnabled(true)
        var expected = queue.queuedItems
        let moved = expected.removeFirst()
        expected.append(moved)

        XCTAssertTrue(queue.moveQueuedItem(from: 0, to: 2))
        XCTAssertEqual(queue.queuedItems, expected)
        XCTAssertEqual(queue.next(), expected.first)
    }

     func testCurrentQueueIndexMatchesDisplayedShufflePosition() throws {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3)])
        queue.setShuffleEnabled(true)
         let itemIndex = try XCTUnwrap(queue.itemIndex(atQueueIndex: 1))

        _ = queue.play(at: itemIndex)

        XCTAssertEqual(queue.currentQueueIndex, 1)
         let currentQueueIndex = try XCTUnwrap(queue.currentQueueIndex)
         XCTAssertEqual(queue.queuedItems[currentQueueIndex], queue.currentTrack)
    }

    func testCachedShuffledPositionTracksNextPreviousAndWrap() throws {
        var queue = PlaybackQueue(items: (1...4).map(track))
        queue.setShuffleEnabled(true)
        queue.setRepeatMode(.all)

        for _ in 0..<6 {
            let expectedIndex = queue.currentQueueIndex.map { ($0 + 1) % queue.entries.count } ?? 0
            XCTAssertNotNil(queue.next())
            XCTAssertEqual(queue.currentQueueIndex, expectedIndex)
        }
        for _ in 0..<6 {
            let expectedIndex = queue.currentQueueIndex.map { ($0 - 1 + queue.entries.count) % queue.entries.count }
            XCTAssertNotNil(queue.previous())
            XCTAssertEqual(queue.currentQueueIndex, expectedIndex)
        }

        let index = try XCTUnwrap(queue.currentQueueIndex)
        XCTAssertEqual(queue.queuedEntries[index], queue.currentEntry)
    }

    func testDisablingShuffleRestoresSequentialNavigation() {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3)])
        _ = queue.play(at: 1)

        queue.setShuffleEnabled(true)
        XCTAssertEqual(queue.currentTrack?.title, "Track 2")
        queue.setShuffleEnabled(false)

        XCTAssertEqual(queue.nextIndex, 2)
        XCTAssertEqual(queue.previousIndex, 0)
    }

    func testInsertNextTakesPriorityWhileShuffled() {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3)])
        queue.setShuffleEnabled(true)
        _ = queue.next()

        queue.insertNext([track(4), track(5)])

        XCTAssertEqual(queue.next()?.title, "Track 4")
        XCTAssertEqual(queue.next()?.title, "Track 5")
    }

     func testRemovingCurrentShuffledTrackDoesNotReplayHistory() throws {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3), track(4)])
        queue.setShuffleEnabled(true)
        let first = queue.next()
        let second = queue.next()
         let currentIndex = try XCTUnwrap(queue.currentIndex)

        _ = queue.remove(at: currentIndex)
        let next = queue.next()

        XCTAssertNotEqual(next, first)
        XCTAssertNotEqual(next, second)
    }

    func testRepeatAllWrapsQueueNavigation() {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3)])
        queue.setRepeatMode(.all)
        _ = queue.play(at: 2)

        XCTAssertEqual(queue.next()?.title, "Track 1")
        XCTAssertEqual(queue.previous()?.title, "Track 3")
    }

    func testRepeatOneReplaysOnlyAfterCompletion() {
        var queue = PlaybackQueue(items: [track(1), track(2), track(3)])
        queue.setRepeatMode(.one)
        _ = queue.play(at: 1)

        XCTAssertEqual(queue.nextIndex, 2)
        queue.markCurrentTrackFinished()

        XCTAssertEqual(queue.playbackIndex, 1)
        XCTAssertFalse(queue.isAtEnd)

        _ = queue.play(at: 2)
        XCTAssertNil(queue.nextIndex)
    }

    func testRepeatModesRepeatStandaloneTrackWhenEnabled() {
        XCTAssertFalse(PlaybackRepeatMode.off.repeatsStandaloneTrack)
        XCTAssertTrue(PlaybackRepeatMode.all.repeatsStandaloneTrack)
        XCTAssertTrue(PlaybackRepeatMode.one.repeatsStandaloneTrack)
    }

    func testReplaceResetsCurrentTrack() {
        var queue = PlaybackQueue(items: [track(1), track(2)], currentIndex: 1)

        queue.replace(with: [track(3)])

        XCTAssertEqual(queue.items.map(\.title), ["Track 3"])
        XCTAssertNil(queue.currentIndex)
        XCTAssertEqual(queue.next()?.title, "Track 3")
    }

    func testTrackIdentitySurvivesMetadataRefreshByIDOrPath() {
         let original = Track(
             id: 7,
             path: "/music/original.flac",
             title: "Old",
             artistDisplay: "Artist",
             albumTitle: "Album",
             genreDisplay: "Genre",
             duration: 1,
             format: "flac"
         )
         let moved = Track(
             id: 7,
             path: "/music/moved.flac",
             title: "New",
             artistDisplay: "Artist",
             albumTitle: "Album",
             genreDisplay: "Genre",
             duration: 1,
             format: "flac"
         )
         let pathOnly = Track(
             path: "/music/original.flac",
             title: "Updated",
             artistDisplay: "Artist",
             albumTitle: "Album",
             genreDisplay: "Genre",
             duration: 1,
             format: "flac"
         )
         let unrelated = Track(
             id: 8,
             path: "/music/other.flac",
             title: "Other",
             artistDisplay: "Artist",
             albumTitle: "Album",
             genreDisplay: "Genre",
             duration: 1,
             format: "flac"
         )

        XCTAssertTrue(original.hasSameIdentity(as: moved))
        XCTAssertTrue(original.hasSameIdentity(as: pathOnly))
        XCTAssertFalse(original.hasSameIdentity(as: unrelated))
    }

    func testDuplicateTracksHaveDistinctStableEntryIdentity() {
        let duplicate = track(1)
        var queue = PlaybackQueue(items: [duplicate, duplicate, track(2)])
        let first = queue.entries[0]
        let second = queue.entries[1]
        let third = queue.entries[2]

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(queue.entry(at: 0)?.id, first.id)
        XCTAssertEqual(queue.entry(at: 1)?.id, second.id)
        XCTAssertEqual(queue.remove(second)?.id, second.id)
        XCTAssertEqual(queue.entries.map(\.id), [first.id, third.id])
    }

    func testDuplicateEntryIdentitySurvivesReorderAndCurrentPlayback() {
        let duplicate = track(1)
        var queue = PlaybackQueue(items: [duplicate, duplicate, track(2)])
        let first = queue.entries[0]
        let second = queue.entries[1]
        let third = queue.entries[2]

        XCTAssertEqual(queue.play(second), second.track)
        XCTAssertEqual(queue.currentEntry?.id, second.id)
        XCTAssertTrue(queue.moveQueuedItem(first, to: 2))
        XCTAssertEqual(queue.entries.map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(queue.currentEntry?.id, second.id)
    }

     func testShuffledDuplicateActionsTargetRequestedEntry() throws {
        let duplicate = track(1)
        var queue = PlaybackQueue(items: [duplicate, duplicate, track(2)])
        queue.setShuffleEnabled(true)
        let target = queue.entries[1]
        let other = queue.entries[0]

         let originalQueueIndex = try XCTUnwrap(queue.queueIndex(of: target))
        XCTAssertEqual(queue.entry(atQueueIndex: originalQueueIndex)?.id, target.id)
        XCTAssertTrue(queue.moveQueuedItem(target, to: 0))
        XCTAssertEqual(queue.queuedEntries.first?.id, target.id)
        XCTAssertEqual(queue.remove(target)?.id, target.id)
        XCTAssertFalse(queue.entries.contains { $0.id == target.id })
        XCTAssertTrue(queue.entries.contains { $0.id == other.id })
    }

    private func track(_ number: Int) -> Track {
         Track(
             path: "/music/track-\(number).flac",
             title: "Track \(number)",
             artistDisplay: "Artist",
             albumTitle: "Album",
             genreDisplay: "Genre",
             duration: 1,
             format: "flac"
         )
    }
}
