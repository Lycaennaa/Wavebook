import Foundation
@testable import WavebookCore
import XCTest

@MainActor
final class LibraryScanCoordinatorRelocationTests: XCTestCase {
    func testRelocatedRootSerializesOldScanAndRemovalWaitsForActiveScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wavebook-\(UUID().uuidString)", isDirectory: true)
        let movedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wavebook-Moved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0]).write(to: root.appendingPathComponent("Song.wav"))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: movedRoot)
        }

        let originalRootPath = LibraryDatabase.canonicalRootPath(root.path)
        let database = try LibraryDatabase(inMemory: true)
        let oldScanGate = LibraryScanGate()
        let movedScanGate = LibraryScanGate()
        let trackCommitGate = LibraryScanGate()
        let coordinator = LibraryScanCoordinator(
            databaseProvider: { database },
            scan: { scanRoot, database, _, _ in
                let rootPath = scanRoot.path
                let tracks: [Track]
                if rootPath == originalRootPath {
                    try await oldScanGate.pauseScan(at: rootPath, ignoresCancellation: true)
                    tracks = []
                } else {
                    try await movedScanGate.pauseScan(at: rootPath, ignoresCancellation: true)
                    tracks = [
                        Track(
                            path: URL(fileURLWithPath: rootPath, isDirectory: true)
                                .appendingPathComponent("Song.wav").path,
                            title: "Song",
                            artistDisplay: "Artist",
                            albumTitle: "Album"
                        )
                    ]
                }
                _ = try await Task.detached {
                    try database.reconcile(rootPath: rootPath, tracks: tracks, lyricFiles: [])
                }.value
                if rootPath != originalRootPath {
                    try await trackCommitGate.pauseScan(at: rootPath, ignoresCancellation: true)
                }
                return LibraryScanResult(
                    tracks: tracks,
                    matchedLyricTrackCount: 0,
                    failures: [],
                    failedCandidateCount: 0
                )
            },
            onEvent: { _ in },
            onLibraryChanged: {},
            onReplayGainStart: {}
        )

        coordinator.addRoots([root])
        await fulfillment(of: [oldScanGate.scanStarted], timeout: 10)
        let registeredRoot = try XCTUnwrap(try database.roots().first)
        try FileManager.default.moveItem(at: root, to: movedRoot)
        let canonicalMovedRootPath = LibraryDatabase.canonicalRootPath(movedRoot.path)

        let rescanCompleted = expectation(description: "Moved root rescan completes")
        var rescanSucceeded: Bool?
        coordinator.rescanPersistedRoots(startReplayGain: false) { succeeded in
            rescanSucceeded = succeeded
            rescanCompleted.fulfill()
        }
        await fulfillment(of: [oldScanGate.scanCancelled], timeout: 10)
        XCTAssertEqual(try database.roots().map(\.path), [registeredRoot.path])
        oldScanGate.resumeScan()

        await fulfillment(of: [movedScanGate.scanStarted], timeout: 10)
        let relocatedRoot = try XCTUnwrap(try database.roots().first)
        XCTAssertEqual(relocatedRoot.id, registeredRoot.id)
        XCTAssertEqual(relocatedRoot.path, canonicalMovedRootPath)
        XCTAssertEqual(try database.roots().map(\.path), [canonicalMovedRootPath])

        let removal = Task { await coordinator.removeRoot(relocatedRoot) }
        await fulfillment(of: [movedScanGate.scanCancelled], timeout: 10)
        movedScanGate.resumeScan()
        await fulfillment(of: [trackCommitGate.scanStarted], timeout: 10)
        XCTAssertEqual(try database.allTracks().map(\.title), ["Song"])
        trackCommitGate.resumeScan()
        await removal.value
        await fulfillment(of: [rescanCompleted], timeout: 10)

        XCTAssertEqual(rescanSucceeded, true)
        XCTAssertTrue(try database.roots().isEmpty)
        XCTAssertTrue(try database.allTracks().isEmpty)
    }
    func testFailedRemovalRescansResolvedMovedFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wavebook-Removal-\(UUID().uuidString)", isDirectory: true)
        let movedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wavebook-Removal-Moved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: movedRoot)
        }

        let database = try LibraryDatabase(inMemory: true)
        let bookmark = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let rootID = try database.addRoot(path: root.path, securityScopedBookmark: bookmark)
        let registeredRoot = try XCTUnwrap(try database.roots().first)
        try FileManager.default.moveItem(at: root, to: movedRoot)
        try await database.writer.write { connection in
            try connection.execute(sql: """
                CREATE TRIGGER failRootRemoval BEFORE DELETE ON roots
                BEGIN
                    SELECT RAISE(ABORT, 'forced root removal failure');
                END
                """)
        }

        let scanStarted = expectation(description: "Recovery scans the relocated folder")
        var scannedRootPath: String?
        let coordinator = LibraryScanCoordinator(
            databaseProvider: { database },
            scan: { scanRoot, _, _, _ in
                scannedRootPath = scanRoot.path
                scanStarted.fulfill()
                return LibraryScanResult(
                    tracks: [],
                    matchedLyricTrackCount: 0,
                    failures: [],
                    failedCandidateCount: 0
                )
            },
            onEvent: { _ in },
            onLibraryChanged: {},
            onReplayGainStart: {}
        )
        await coordinator.removeRoot(registeredRoot)
        await fulfillment(of: [scanStarted], timeout: 10)

        let persistedRoot = try XCTUnwrap(try database.roots().first)
        XCTAssertEqual(scannedRootPath, LibraryDatabase.canonicalRootPath(movedRoot.path))
        XCTAssertEqual(persistedRoot.id, rootID)
        XCTAssertEqual(persistedRoot.path, LibraryDatabase.canonicalRootPath(movedRoot.path))
        let persistedBookmark = try XCTUnwrap(persistedRoot.securityScopedBookmark)
        var isStale = false
        let resolvedBookmark = try XCTUnwrap(try? URL(
            resolvingBookmarkData: persistedBookmark,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ))
        XCTAssertEqual(
            LibraryDatabase.canonicalRootPath(resolvedBookmark.path),
            LibraryDatabase.canonicalRootPath(movedRoot.path)
        )
    }
}
