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
        XCTAssertEqual(
            Set(scanStates.compactMap { $0.progress?.root.lastPathComponent }),
            Set(["first", "second"])
        )
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
