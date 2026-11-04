import Foundation
import WavebookCore

struct LibraryScanSnapshot: Equatable, Sendable {
    let isScanning: Bool
    let progress: LibraryRootScanProgress?
    let lastCompletedMatchedLyricsCount: LibraryRootMatchedLyricsCount?
    let failure: LibraryRootScanFailure?

    init(
        isScanning: Bool,
        progress: LibraryRootScanProgress?,
        lastCompletedMatchedLyricsCount: LibraryRootMatchedLyricsCount? = nil,
        failure: LibraryRootScanFailure?
    ) {
        self.isScanning = isScanning
        self.progress = progress
        self.lastCompletedMatchedLyricsCount = lastCompletedMatchedLyricsCount
        self.failure = failure
    }
}

typealias LibraryRootScanOperation = @MainActor (
    URL,
    LibraryDatabase,
    UUID,
    @escaping LibraryScanProgressHandler
) async throws -> LibraryScanResult

final class ScopedRootAccess: Sendable {
    private let url: URL
    private let didStartAccessing: Bool

    init(url: URL) {
        self.url = url
        didStartAccessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

struct RootPathUpdate: Sendable {
    let path: String
    let securityScopedBookmark: Data?
}

struct AvailableRootScan {
    let rootID: Int64
    let scanRoot: URL
    let scanKey: String
    let access: ScopedRootAccess
    let pathUpdate: RootPathUpdate
}

enum RootScanAccess: Sendable {
    case selectedFolder
    case persisted(
        rootID: Int64,
        access: ScopedRootAccess,
        scanKey: String,
        pathUpdate: RootPathUpdate?
    )
}
