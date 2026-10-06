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
            scan: { root, database, generation in
                try await gate.pauseScan(at: root.path)
                return try await scanner.scan(root: root, database: database, generation: generation)
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
