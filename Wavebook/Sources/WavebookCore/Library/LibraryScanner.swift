import Foundation

public struct LibraryScanDiagnostic: Hashable, Sendable {
    public let path: String
    public let reason: String

    static let maximumCount = 100
    private static let maximumReasonLength = 256

    static func boundedReason(for error: Error) -> String {
        boundedReason(for: error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription)
    }

    static func boundedReason(for reason: String) -> String {
        String(reason.prefix(maximumReasonLength))
    }
}

/// Result of scanning and reconciling a library root.
public struct LibraryScanResult: Sendable {
    /// Successfully discovered tracks in the root, each carrying its persisted catalog ID.
    /// Tracks preserved because scanning failed are omitted.
    public let tracks: [Track]
    /// Bounded diagnostics for failed candidates.
    public let failures: [LibraryScanDiagnostic]
    /// Total number of failed candidates before diagnostic truncation.
    public let failedCandidateCount: Int

    /// Number of failures omitted from the diagnostic list.
    public var omittedFailureCount: Int {
        max(0, failedCandidateCount - failures.count)
    }

    init(tracks: [Track], failures: [LibraryScanDiagnostic], failedCandidateCount: Int) {
        self.tracks = tracks
        self.failures = failures
        self.failedCandidateCount = max(failedCandidateCount, failures.count)
    }
}

/// Discovers audio and lyric files for a library root.
public actor LibraryScanner {
    /// File extensions scanned as native audio candidates.
    public static let supportedExtensions = AudioFormatSupport.nativeCandidateExtensions
    private let metadataReader: AudioMetadataReader
    private let preservedFailurePathLimit: Int
    private let discoveryEntryLimit: Int

    private var scanGenerations: [String: UUID] = [:]

    /// Creates a scanner using the supplied metadata reader.
    public init(metadataReader: AudioMetadataReader = AudioMetadataReader()) {
        self.metadataReader = metadataReader
        preservedFailurePathLimit = LibraryFileDiscovery.maximumPreservedFailurePathCount
        discoveryEntryLimit = LibraryFileDiscovery.maximumDiscoveredEntryCount
    }
    init(
        preservedFailurePathLimit: Int,
        maximumDiscoveredEntryCount: Int? = nil
    ) {
        metadataReader = AudioMetadataReader()
        self.preservedFailurePathLimit = preservedFailurePathLimit
        discoveryEntryLimit = maximumDiscoveredEntryCount ?? LibraryFileDiscovery.maximumDiscoveredEntryCount
    }

    /// Discovers supported audio files under a library root.
    public func discoverFiles(in root: URL) throws -> [URL] {
        try LibraryFileDiscovery.discoverFilesAndLyrics(
            in: root,
            includeAudio: true,
            includeLyrics: false,
            preservedFailurePathLimit: preservedFailurePathLimit,
            entryLimit: discoveryEntryLimit
        ).audio
    }

    /// Discovers lyric files under a library root.
    public func discoverLyricFiles(in root: URL) throws -> [URL] {
        try LibraryFileDiscovery.discoverFilesAndLyrics(
            in: root,
            includeAudio: false,
            includeLyrics: true,
            preservedFailurePathLimit: preservedFailurePathLimit,
            entryLimit: discoveryEntryLimit
        ).lyrics
    }

}

extension LibraryScanner {
    /// Scans a library root and reconciles its catalog.
    @discardableResult
    public func scan(
        root: URL,
        database: LibraryDatabase,
        generation: UUID = UUID()
    ) async throws -> LibraryScanResult {
        let rootPath = try LibraryDatabase.resolveRootPath(root.standardizedFileURL.path)
        try Task.checkCancellation()
        scanGenerations[rootPath] = generation
        defer {
            if scanGenerations[rootPath] == generation {
                scanGenerations[rootPath] = nil
            }
        }

        let discovered = try LibraryFileDiscovery.discoverFilesAndLyrics(
            in: root,
            includeAudio: true,
            includeLyrics: true,
            preservedFailurePathLimit: preservedFailurePathLimit,
            entryLimit: discoveryEntryLimit
        )
        return try await scanDiscoveredRoot(
            root: root,
            rootPath: rootPath,
            generation: generation,
            database: database,
            discovered: discovered
        )
    }

    private func scanDiscoveredRoot(
        root: URL,
        rootPath: String,
        generation: UUID,
        database: LibraryDatabase,
        discovered: LibraryDiscoveryResult
    ) async throws -> LibraryScanResult {
        guard !discovered.preservationLimitExceeded else {
            throw LibraryScannerError.tooManyPreservedFailurePaths(root, limit: preservedFailurePathLimit)
        }
        var reusableTracks = try database.scanReuseEntries(rootPath: rootPath)
        let reusableTrackPaths = Set(reusableTracks.keys)
        var collection = try await collectScanCollection(
            discovered: discovered,
            rootPath: rootPath,
            generation: generation,
            reusableTracks: reusableTracks
        )
        let discoveredTrackPaths = Set(collection.tracks.map(\.path))
        reusableTracks.removeAll(keepingCapacity: false)
        let canCompleteUnchangedScan = reusableTrackPaths == discoveredTrackPaths
            && reusableTrackPaths.count == discovered.audio.count
            && collection.tracks.count == discovered.audio.count
            && collection.changedTracks.isEmpty
            && discovered.failureCount == 0
            && discovered.failedLyricPaths.isEmpty
        if canCompleteUnchangedScan,
           try database.completeUnchangedScan(rootPath: rootPath, lyricFiles: discovered.lyrics) {
            collection.tracks.sort { CatalogFacetOrdering.localizedPathPrecedes($0.path, $1.path) }
            return LibraryScanResult(
                tracks: collection.tracks,
                failures: collection.failures,
                failedCandidateCount: collection.failedCandidateCount
            )
        }

        var preservedPaths = Set<String>()
        if !collection.failedCandidatePaths.isEmpty {
            preservedPaths = try database.reconcileFailedCandidates(
                rootPath: rootPath,
                paths: collection.failedCandidatePaths
            )
        }
        try checkScanGeneration(rootPath: rootPath, generation: generation)
        collection.tracks.sort { CatalogFacetOrdering.localizedPathPrecedes($0.path, $1.path) }
        let persistedTracks = try persistScanChanges(
            collection: collection,
            rootPath: rootPath,
            discovered: discovered,
            database: database,
            preservedPaths: preservedPaths
        )
        return LibraryScanResult(
            tracks: persistedTracks,
            failures: collection.failures,
            failedCandidateCount: collection.failedCandidateCount
        )
    }

    private func persistScanChanges(
        collection: ScanCollection,
        rootPath: String,
        discovered: LibraryDiscoveryResult,
        database: LibraryDatabase,
        preservedPaths: Set<String>
    ) throws -> [Track] {
        let input = CatalogReconcileInput(
            rootPath: rootPath,
            tracks: collection.changedTracks,
            expectedPaths: Set(collection.tracks.map(\.path)),
            lyricFiles: discovered.lyrics,
            preservedPaths: preservedPaths,
            preservedLyricPaths: discovered.failedLyricPaths
        )
        let persistedChangedTracks = try database.reconcileIncremental(input)
        var persistedChangedTracksByPath: [String: Track] = [:]
        for track in persistedChangedTracks {
            persistedChangedTracksByPath[track.path] = track
        }
        return collection.tracks.map { persistedChangedTracksByPath[$0.path] ?? $0 }
    }

    private func collectScanCollection(
        discovered: LibraryDiscoveryResult,
        rootPath: String,
        generation: UUID,
        reusableTracks: [String: LibraryScanReuseEntry]
    ) async throws -> ScanCollection {
        let metadataReader = metadataReader
        // Measurements favor more overlap through 1,000 tracks and a lower cap at larger scales.
        let maximumConcurrentCount = discovered.audio.count > 1_000 ? 4 : 8
        var results = try await BoundedTaskRunner.run(
            items: discovered.audio,
            maximumConcurrentCount: maximumConcurrentCount,
            cancellationCheck: { try Task.checkCancellation() },
            operation: { url in
                try await LibraryScanCandidateLoader.candidateResult(
                    for: url,
                    metadataReader: metadataReader,
                    reusableTracks: reusableTracks
                )
            }
        )

        try checkScanGeneration(rootPath: rootPath, generation: generation)
        let collection = try Self.collectScanResults(&results, discovered: discovered)
        try checkScanGeneration(rootPath: rootPath, generation: generation)
        return collection
    }

    private func checkScanGeneration(rootPath: String, generation: UUID) throws {
        try Task.checkCancellation()
        guard scanGenerations[rootPath] == generation else { throw CancellationError() }
    }

    private struct ScanCollection {
        var tracks: [Track]
        var changedTracks: [Track]
        let failures: [LibraryScanDiagnostic]
        let failedCandidateCount: Int
        let failedCandidatePaths: Set<String>
    }

    private static func collectScanResults(
        _ results: inout [LibraryScanCandidateResult],
        discovered: LibraryDiscoveryResult
    ) throws -> ScanCollection {
        var tracks: [Track] = []
        tracks.reserveCapacity(results.count)
        var changedTracks: [Track] = []
        var failures = discovered.diagnostics
        var failedCandidateCount = discovered.failureCount
        var failedCandidatePaths = discovered.failedAudioPaths
        results.sort { CatalogFacetOrdering.localizedPathPrecedes($0.url.path, $1.url.path) }
        for result in results {
            switch result {
            case let .reused(_, track):
                tracks.append(track)
            case let .loaded(_, track):
                tracks.append(track)
                changedTracks.append(track)
            case let .failure(url, resultFailureReason):
                failedCandidateCount += 1
                let displayPath = url.standardizedFileURL.path
                var failureReason = resultFailureReason
                do {
                    failedCandidatePaths.insert(try LibraryDatabase.resolveRootPath(displayPath))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failureReason = LibraryScanDiagnostic.boundedReason(for: error)
                }
                if failures.count < LibraryScanDiagnostic.maximumCount {
                    failures.append(LibraryScanDiagnostic(path: displayPath, reason: failureReason))
                }
            }
        }
        return ScanCollection(
            tracks: tracks,
            changedTracks: changedTracks,
            failures: failures,
            failedCandidateCount: failedCandidateCount,
            failedCandidatePaths: failedCandidatePaths
        )
    }

    /// Creates a metadata-free track for a URL.
    public static func stubTrack(for url: URL) -> Track {
        MetadataParser.track(for: url, duration: 0)
    }

}
