import Foundation
@testable import WavebookCore
import XCTest

final class CatalogFacetQueryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [CatalogFacetQueryEvent] = []

    func append(_ event: CatalogFacetQueryEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    func events(for kind: CatalogFacetKind, stage: CatalogFacetQueryStage) -> [CatalogFacetQueryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents.filter { $0.kind == kind && $0.stage == stage }
    }
}

final class CatalogAlbumInvalidationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedInvalidations: [Set<AlbumKey>] = []

    func append(_ albumKeys: Set<AlbumKey>) {
        lock.lock()
        recordedInvalidations.append(albumKeys)
        lock.unlock()
    }

    var invalidations: [Set<AlbumKey>] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvalidations
    }
}

final class CatalogReconcileCancellationProbe: @unchecked Sendable {
    let token = LibraryDatabaseCancellationToken()
    private let lock = NSLock()
    private let cancellationPhase: CatalogReconcileTesting.Phase
    private let cancellationCheckpoint: Int
    private var phaseCheckpointCount = 0

    init(phase: CatalogReconcileTesting.Phase, cancellationCheckpoint: Int) {
        self.cancellationPhase = phase
        self.cancellationCheckpoint = cancellationCheckpoint
    }

    func checkpoint(_ phase: CatalogReconcileTesting.Phase) {
        guard phase == cancellationPhase else { return }
        lock.lock()
        phaseCheckpointCount += 1
        let shouldCancel = phaseCheckpointCount == cancellationCheckpoint
        lock.unlock()
        if shouldCancel {
            token.cancel()
        }
    }
}

final class CatalogTests: XCTestCase {
}
