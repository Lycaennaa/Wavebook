import Foundation
@testable import WavebookCore
import XCTest

@MainActor
final class LibraryScanCoordinatorTests: XCTestCase {
    func testSymlinkAliasRemovalCancelsMatchingScanAndSurvivesCancel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wavebook-\(UUID().uuidString)", isDirectory: true)
        let alias = root.deletingLastPathComponent()
            .appendingPathComponent("Wavebook-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: root)
        }

        let database = try LibraryDatabase(inMemory: true)
        let gate = LibraryScanGate()
        let scanner = LibraryScanner()
        let coordinator = LibraryScanCoordinator(
            databaseProvider: { database },
            scan: { root, database, generation, progress in
                try await gate.pauseScan(at: root.path)
                return try await scanner.scan(
                    root: root,
                    database: database,
                    generation: generation,
                    progress: progress
                )
            },
            onEvent: { _ in },
            onLibraryChanged: {},
            onReplayGainStart: {}
        )

        coordinator.addRoots([alias])
        await fulfillment(of: [gate.scanStarted], timeout: 10)
        let registeredRoot = try XCTUnwrap(try database.roots().first)
        XCTAssertEqual(gate.scannedRootPath, registeredRoot.path)
        let removal = Task { await coordinator.removeRoot(registeredRoot) }
        await fulfillment(of: [gate.scanCancelled], timeout: 10)
        coordinator.cancel()
        gate.resumeScan()
        await removal.value

        XCTAssertTrue(try database.roots().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testRemovingLastRootPublishesUpdatedScanState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wavebook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try LibraryDatabase(inMemory: true)
        _ = try database.addRoot(path: root.path)
        let registeredRoot = try XCTUnwrap(try database.roots().first)
        let scanCompleted = expectation(description: "Root scan completes")
        let emptyRootStatePublished = expectation(description: "Empty root state is published")
        let coordinator = LibraryScanCoordinator(
            databaseProvider: { database },
            scan: { _, _, _, progress in
                await progress(0, 0)
                return LibraryScanResult(
                    tracks: [],
                    matchedLyricTrackCount: 1,
                    failures: [],
                    failedCandidateCount: 0
                )
            },
            onEvent: { _ in },
            onLibraryChanged: {},
            onReplayGainStart: {},
            onScanStateChanged: { snapshot in
                if !snapshot.isScanning,
                   snapshot.lastCompletedMatchedLyricsCount?.matchedLyricTrackCount == 1 {
                    scanCompleted.fulfill()
                }
                if !snapshot.isScanning,
                   snapshot.lastCompletedMatchedLyricsCount == nil,
                   (try? database.roots().isEmpty) == true {
                    emptyRootStatePublished.fulfill()
                }
            }
        )

        coordinator.rescanPersistedRoots(startReplayGain: false)
        await fulfillment(of: [scanCompleted], timeout: 10)
        await coordinator.removeRoot(registeredRoot)
        await fulfillment(of: [emptyRootStatePublished], timeout: 10)

        XCTAssertTrue(try database.roots().isEmpty)
    }

    func testAddingMultipleRootsKeepsScanActivityUntilAllScansFinish() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wavebook-\(UUID().uuidString)", isDirectory: true)
        let roots = [
            parent.appendingPathComponent("first", isDirectory: true),
            parent.appendingPathComponent("second", isDirectory: true)
        ]
        for root in roots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try Data("[00:00.00]One\n".utf8).write(to: roots[0].appending(path: "One.lrc"))
        try Data("[00:00.00]Two\n".utf8).write(to: roots[0].appending(path: "Two.lrc"))
        try Data("[00:00.00]Three\n".utf8).write(to: roots[1].appending(path: "Three.lrc"))
        defer { try? FileManager.default.removeItem(at: parent) }

        let database = try LibraryDatabase(inMemory: true)
        let scanCompleted = expectation(description: "Both roots finish scanning")
        scanCompleted.expectedFulfillmentCount = roots.count
        var scanStates: [LibraryScanSnapshot] = []
        let scanner = LibraryScanner()
        let coordinator = LibraryScanCoordinator(
            databaseProvider: { database },
            scan: { root, database, generation, progress in
                return try await scanner.scan(
                    root: root,
                    database: database,
                    generation: generation,
                    progress: progress
                )
            },
            onEvent: { _ in },
            onLibraryChanged: { scanCompleted.fulfill() },
            onReplayGainStart: {},
            onScanStateChanged: { snapshot in scanStates.append(snapshot) }
        )

        coordinator.addRoots(roots)
        XCTAssertTrue(scanStates.first?.isScanning ?? false)
        await fulfillment(of: [scanCompleted], timeout: 10)

        let registeredRootNames = try database.roots().map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertEqual(Set(registeredRootNames), Set(["first", "second"]))
        let finalSnapshot = try XCTUnwrap(scanStates.last)
        XCTAssertFalse(finalSnapshot.isScanning)
        XCTAssertEqual(finalSnapshot.progress?.root.lastPathComponent, "second")
        XCTAssertEqual(finalSnapshot.progress?.completedFileCount, 0)
        XCTAssertEqual(finalSnapshot.progress?.totalFileCount, 0)
        XCTAssertEqual(finalSnapshot.progress?.matchedLyricTrackCount, 0)
        XCTAssertTrue(scanStates.contains { snapshot in
            snapshot.isScanning
                && snapshot.lastCompletedMatchedLyricsCount?.root.lastPathComponent == "first"
                && snapshot.lastCompletedMatchedLyricsCount?.matchedLyricTrackCount == 0
        })
        XCTAssertEqual(
            Set(scanStates.compactMap { $0.progress?.root.lastPathComponent }),
            Set(["first", "second"])
        )
    }

    func testScanCountsTracksWithMatchedLyrics() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wavebook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try LibraryDatabase(inMemory: true)
        let scanCompleted = expectation(description: "Scan returns matched tracks")
        let coordinator = LibraryScanCoordinator(
            databaseProvider: { database },
            scan: { root, _, _, progress in
                await progress(0, 2)
                return LibraryScanResult(
                    tracks: [
                        Track(
                            path: root.appending(path: "Matched.wav").path,
                            title: "Matched",
                            artistDisplay: "Artist",
                            albumTitle: "",
                            hasLyrics: true
                        ),
                        Track(
                            path: root.appending(path: "Unmatched.wav").path,
                            title: "Unmatched",
                            artistDisplay: "Artist",
                            albumTitle: "",
                            hasLyrics: false
                        )
                    ],
                    matchedLyricTrackCount: 1,
                    failures: [],
                    failedCandidateCount: 0
                )
            },
            onEvent: { _ in },
            onLibraryChanged: {},
            onReplayGainStart: {},
            onScanStateChanged: { snapshot in
                if !snapshot.isScanning, snapshot.progress?.matchedLyricTrackCount == 1 {
                    scanCompleted.fulfill()
                }
            }
        )

        coordinator.addRoots([root])
        await fulfillment(of: [scanCompleted], timeout: 10)

        XCTAssertEqual(coordinator.snapshot.progress?.matchedLyricTrackCount, 1)
    }

    func testUnavailableMatchedLyricsCountDoesNotFailCompletedScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wavebook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try LibraryDatabase(inMemory: true)
        let libraryChanged = expectation(description: "Committed scan refreshes library")
        let scanCompleted = expectation(description: "Scan completes without a lyric count")
        let coordinator = LibraryScanCoordinator(
            databaseProvider: { database },
            scan: { _, _, _, progress in
                await progress(0, 0)
                return LibraryScanResult(
                    tracks: [],
                    matchedLyricTrackCount: nil,
                    failures: [],
                    failedCandidateCount: 0
                )
            },
            onEvent: { _ in },
            onLibraryChanged: { libraryChanged.fulfill() },
            onReplayGainStart: {},
            onScanStateChanged: { snapshot in
                if !snapshot.isScanning, snapshot.progress != nil {
                    scanCompleted.fulfill()
                }
            }
        )

        coordinator.addRoots([root])
        await fulfillment(of: [libraryChanged, scanCompleted], timeout: 10)

        XCTAssertNil(coordinator.snapshot.failure)
        XCTAssertNil(coordinator.snapshot.progress?.matchedLyricTrackCount)
    }

    func testLaterSuccessfulRootClearsEarlierScanFailure() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wavebook-\(UUID().uuidString)", isDirectory: true)
        let roots = [
            parent.appendingPathComponent("first", isDirectory: true),
            parent.appendingPathComponent("second", isDirectory: true)
        ]
        for root in roots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: parent) }

        let database = try LibraryDatabase(inMemory: true)
        let secondRootCompleted = expectation(description: "Second root scan completes")
        let coordinator = LibraryScanCoordinator(
            databaseProvider: { database },
            scan: { root, _, _, progress in
                guard root.lastPathComponent == "second" else {
                    throw NSError(domain: "LibraryScanCoordinatorTests", code: 1)
                }
                await progress(1, 1)
                return LibraryScanResult(
                    tracks: [Track(
                        path: root.appending(path: "Matched.wav").path,
                        title: "Matched",
                        artistDisplay: "Artist",
                        albumTitle: "",
                        hasLyrics: true
                    )],
                    matchedLyricTrackCount: 1,
                    failures: [],
                    failedCandidateCount: 0
                )
            },
            onEvent: { _ in },
            onLibraryChanged: {},
            onReplayGainStart: {},
            onScanStateChanged: { snapshot in
                if !snapshot.isScanning, snapshot.progress?.root.lastPathComponent == "second" {
                    secondRootCompleted.fulfill()
                }
            }
        )

        coordinator.addRoots(roots)
        await fulfillment(of: [secondRootCompleted], timeout: 10)

        XCTAssertNil(coordinator.snapshot.failure)
        XCTAssertEqual(coordinator.snapshot.progress?.root.lastPathComponent, "second")
        XCTAssertEqual(coordinator.snapshot.progress?.matchedLyricTrackCount, 1)
    }

    func testScanFailureBeforeProgressIsRetainedInSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wavebook-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let database = try LibraryDatabase(inMemory: true)
        let scanEnded = expectation(description: "Failed scan ends without progress")
        let coordinator = LibraryScanCoordinator(
            databaseProvider: { database },
            scan: { _, _, _, _ in throw NSError(domain: "LibraryScanCoordinatorTests", code: 1) },
            onEvent: { _ in },
            onLibraryChanged: {},
            onReplayGainStart: {},
            onScanStateChanged: { snapshot in
                if !snapshot.isScanning { scanEnded.fulfill() }
            }
        )

        coordinator.addRoots([root])
        await fulfillment(of: [scanEnded], timeout: 10)

        let snapshot = coordinator.snapshot
        XCTAssertFalse(snapshot.isScanning)
        XCTAssertNil(snapshot.progress)
        XCTAssertEqual(snapshot.failure?.root.lastPathComponent, "Music")
    }
}

@MainActor
private final class LibraryScanGate {
    let scanStarted = XCTestExpectation(description: "Canonical scan starts")
    let scanCancelled = XCTestExpectation(description: "Root removal cancels scan")
    private(set) var scannedRootPath: String?
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pauseScan(at rootPath: String) async throws {
        scannedRootPath = rootPath
        scanStarted.fulfill()
        try await withTaskCancellationHandler {
            await withCheckedContinuation { resumeContinuation = $0 }
            try Task.checkCancellation()
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.scanCancelled.fulfill()
            }
        }
    }

    func resumeScan() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
