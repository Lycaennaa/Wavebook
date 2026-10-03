import Foundation

struct LibraryDiscoveryResult: Sendable {
    let audio: [URL]
    let lyrics: [URL]
    let diagnostics: [LibraryScanDiagnostic]
    let failedAudioPaths: Set<String>
    let failedLyricPaths: Set<String>
    let failureCount: Int
    let preservationLimitExceeded: Bool
}

enum LibraryFileDiscovery {
    static let maximumAudioFileCount = 50_000
    static let maximumPreservedFailurePathCount = 50_000
    static let maximumLyricFileCount = 50_000
    static let maximumDiscoveredEntryCount = 250_000
    private final class DiscoveryAccumulator {
        var hiddenDirectories = Set<String>()
        var audioURLs: [URL] = []
        var audioPaths = Set<String>()
        var lyricPaths = Set<String>()
        var lyricURLs: [URL] = []
        var diagnostics: [LibraryScanDiagnostic] = []
        var failedAudioPaths = Set<String>()
        var failedLyricPaths = Set<String>()
        var failureCount = 0
        let preservedFailurePathLimit: Int
        var preservationLimitExceeded = false

        init(preservedFailurePathLimit: Int) {
            self.preservedFailurePathLimit = preservedFailurePathLimit
        }
        var visitedEntryCount = 0

        func recordVisitedEntry(root: URL, limit: Int) throws {
            visitedEntryCount += 1
            guard visitedEntryCount <= limit else {
                throw LibraryScannerError.tooManyDiscoveredEntries(root, limit: limit)
            }
        }

        func isInsideHiddenDirectory(_ path: String, rootPath: String) -> Bool {
            var ancestor = URL(fileURLWithPath: path).deletingLastPathComponent().path
            while ancestor != rootPath {
                if hiddenDirectories.contains(ancestor) { return true }
                let parent = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
                guard parent != ancestor else { return false }
                ancestor = parent
            }
            return false
        }

        func recordFailure(
            path: String,
            reason: String,
            preserveAudio: Bool = false,
            preserveLyric: Bool = false
        ) {
            failureCount += 1
            if preserveAudio { preserve(path, in: &failedAudioPaths) }
            if preserveLyric { preserve(path, in: &failedLyricPaths) }
            guard diagnostics.count < LibraryScanDiagnostic.maximumCount else { return }
            diagnostics.append(
                LibraryScanDiagnostic(
                    path: path,
                    reason: LibraryScanDiagnostic.boundedReason(for: reason)
                )
            )
        }
        private func preserve(_ path: String, in paths: inout Set<String>) {
            guard !paths.contains(path) else { return }
            guard paths.count < preservedFailurePathLimit else {
                preservationLimitExceeded = true
                return
            }
            paths.insert(path)
        }

        func result() -> LibraryDiscoveryResult {
            LibraryDiscoveryResult(
                audio: audioURLs.sorted { CatalogFacetOrdering.localizedPathPrecedes($0.path, $1.path) },
                lyrics: lyricURLs.sorted { CatalogFacetOrdering.localizedPathPrecedes($0.path, $1.path) },
                diagnostics: diagnostics,
                failedAudioPaths: failedAudioPaths,
                failedLyricPaths: failedLyricPaths,
                failureCount: failureCount,
                preservationLimitExceeded: preservationLimitExceeded
            )
        }
    }

    private struct DiscoveryContext {
        let root: URL
        let rootPath: String
        let rootIdentity: RootPathIdentity
        let includeAudio: Bool
        let includeLyrics: Bool
        let enumerator: FileManager.DirectoryEnumerator
        let accumulator: DiscoveryAccumulator
        let entryLimit: Int
    }

    static func discoverFilesAndLyrics(
        in root: URL,
        includeAudio: Bool,
        includeLyrics: Bool,
        preservedFailurePathLimit: Int,
        entryLimit: Int
    ) throws -> LibraryDiscoveryResult {
        let rootIdentity = try LibraryDatabase.rootPathIdentity(for: root.standardizedFileURL.path)
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
            options: [],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw LibraryScannerError.cannotEnumerate(root)
        }
        let accumulator = DiscoveryAccumulator(preservedFailurePathLimit: preservedFailurePathLimit)
        let context = DiscoveryContext(
            root: root,
            rootPath: rootIdentity.path,
            rootIdentity: rootIdentity,
            includeAudio: includeAudio,
            includeLyrics: includeLyrics,
            enumerator: enumerator,
            accumulator: accumulator,
            entryLimit: entryLimit
        )
        while true {
            let didVisitEntry = try autoreleasepool {
                guard let url = context.enumerator.nextObject() as? URL else { return false }
                try Task.checkCancellation()
                try Self.processDiscoveryURL(url, context: context)
                return true
            }
            guard didVisitEntry else { break }
        }
        if let traversalError { throw traversalError }
        return accumulator.result()
    }

    private static func processDiscoveryURL(_ url: URL, context: DiscoveryContext) throws {
        let displayPath = url.standardizedFileURL.path
        let fileFlags = try Self.discoveryFileFlags(for: url, context: context)
        let path: String
        do {
            path = try LibraryDatabase.resolveRootPath(displayPath)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if fileFlags.isAudioCandidate || fileFlags.isLyricCandidate {
                context.accumulator.recordFailure(
                    path: displayPath,
                    reason: LibraryScanDiagnostic.boundedReason(for: error),
                    preserveAudio: fileFlags.isAudioCandidate,
                    preserveLyric: fileFlags.isLyricCandidate
                )
            }
            context.enumerator.skipDescendants()
            return
        }
        guard LibraryDatabase.canonicalPathIsContained(
            path,
            in: context.rootPath,
            caseSensitive: context.rootIdentity.isCaseSensitive
        ) else {
            if fileFlags.isAudioCandidate || fileFlags.isLyricCandidate {
                context.accumulator.recordFailure(
                    path: displayPath,
                    reason: "Candidate resolves outside selected root"
                )
            }
            context.enumerator.skipDescendants()
            return
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            context.accumulator.recordFailure(
                path: displayPath,
                reason: LibraryScanDiagnostic.boundedReason(for: error),
                preserveAudio: fileFlags.isAudioCandidate,
                preserveLyric: fileFlags.isLyricCandidate
            )
            context.enumerator.skipDescendants()
            return
        }
        try Self.processDiscoveryValues(
            candidate: DiscoveryCandidate(
                url: url,
                path: path,
                values: values,
                fileFlags: fileFlags
            ),
            context: context
        )
    }

    private struct DiscoveryFileFlags {
        let isAudioCandidate: Bool
        let isLyricCandidate: Bool
        let countsTowardEntryLimit: Bool
    }

    private static func discoveryFileFlags(
        for url: URL,
        context: DiscoveryContext
    ) throws -> DiscoveryFileFlags {
        let isAudioFile = AudioFormatSupport.shouldScan(url)
        let isLyricFile = url.pathExtension.caseInsensitiveCompare("lrc") == .orderedSame
        let countsTowardEntryLimit = isAudioFile || isLyricFile || AudioArtworkSidecarReader.isSidecarCandidate(url)
        if countsTowardEntryLimit {
            try context.accumulator.recordVisitedEntry(root: context.root, limit: context.entryLimit)
        }
        return DiscoveryFileFlags(
            isAudioCandidate: context.includeAudio && isAudioFile,
            isLyricCandidate: context.includeLyrics && isLyricFile,
            countsTowardEntryLimit: countsTowardEntryLimit
        )
    }

    private struct DiscoveryCandidate {
        let url: URL
        let path: String
        let values: URLResourceValues
        let fileFlags: DiscoveryFileFlags
    }

    private static func processDiscoveryValues(
        candidate: DiscoveryCandidate,
        context: DiscoveryContext
    ) throws {
        let values = candidate.values
        if values.isDirectory == true {
            if !candidate.fileFlags.countsTowardEntryLimit {
                try context.accumulator.recordVisitedEntry(root: context.root, limit: context.entryLimit)
            }
            if values.isHidden == true { context.accumulator.hiddenDirectories.insert(candidate.path) }
            if candidate.fileFlags.isAudioCandidate || candidate.fileFlags.isLyricCandidate {
                context.accumulator.recordFailure(
                    path: candidate.url.standardizedFileURL.path,
                    reason: "Candidate not a regular file",
                    preserveAudio: candidate.fileFlags.isAudioCandidate,
                    preserveLyric: candidate.fileFlags.isLyricCandidate
                )
                context.enumerator.skipDescendants()
            }
            return
        }
        guard values.isRegularFile == true else {
            if candidate.fileFlags.isAudioCandidate || candidate.fileFlags.isLyricCandidate {
                context.accumulator.recordFailure(
                    path: candidate.url.standardizedFileURL.path,
                    reason: "Candidate is not a regular file",
                    preserveAudio: candidate.fileFlags.isAudioCandidate,
                    preserveLyric: candidate.fileFlags.isLyricCandidate
                )
            }
            return
        }
        try Self.appendLyricIfNeeded(candidate, context: context)
        try Self.appendAudioIfNeeded(candidate, context: context)
    }

    private static func appendLyricIfNeeded(
        _ candidate: DiscoveryCandidate,
        context: DiscoveryContext
    ) throws {
        guard candidate.fileFlags.isLyricCandidate,
              context.accumulator.lyricPaths.insert(candidate.path).inserted else { return }
        guard context.accumulator.lyricURLs.count < Self.maximumLyricFileCount else {
            throw LibraryScannerError.tooManyLyricFiles(context.root, limit: Self.maximumLyricFileCount)
        }
        context.accumulator.lyricURLs.append(URL(fileURLWithPath: candidate.path))
    }

    private static func appendAudioIfNeeded(
        _ candidate: DiscoveryCandidate,
        context: DiscoveryContext
    ) throws {
        guard candidate.fileFlags.isAudioCandidate,
              candidate.values.isHidden != true,
              !context.accumulator.isInsideHiddenDirectory(candidate.path, rootPath: context.rootPath),
              context.accumulator.audioPaths.insert(candidate.path).inserted else { return }
        guard context.accumulator.audioURLs.count < Self.maximumAudioFileCount else {
            throw LibraryScannerError.tooManyAudioFiles(context.root, limit: Self.maximumAudioFileCount)
        }
        context.accumulator.audioURLs.append(URL(fileURLWithPath: candidate.path))
    }

}
