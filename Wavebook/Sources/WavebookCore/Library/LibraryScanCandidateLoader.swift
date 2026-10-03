import Foundation

enum LibraryScanCandidateResult: Sendable {
    case reused(url: URL, track: Track)
    case loaded(url: URL, track: Track)
    case failure(url: URL, reason: String)

    var url: URL {
        switch self {
        case let .reused(url, _), let .loaded(url, _), let .failure(url, _): url
        }
    }
}

enum LibraryScanCandidateLoader {
    static func candidateResult(
        for url: URL,
        metadataReader: AudioMetadataReader,
        reusableTracks: [String: LibraryScanReuseEntry]
    ) async throws -> LibraryScanCandidateResult {
        do {
            try Task.checkCancellation()
            let canonicalPath = try LibraryDatabase.resolveRootPath(url.standardizedFileURL.path)
            if let cached = reusableTracks[canonicalPath] {
                let currentFingerprint = ReplayGainFileFingerprint.metadata(path: canonicalPath)
                if currentFingerprint.modificationDate != nil,
                   currentFingerprint.modificationDate == cached.fingerprint.modificationDate,
                   currentFingerprint.fileSize != nil,
                   currentFingerprint.fileSize == cached.fingerprint.fileSize,
                   try AudioMetadataPreflight.allowsAVFoundationMetadata(for: url) {
                    let identity = CatalogResourceIdentity(url: url)
                    if identity?.resourceIdentifier == cached.track.fileResourceIdentifier,
                       identity?.volumeIdentifier == cached.track.fileVolumeIdentifier {
                        var track = cached.track
                        track.path = canonicalPath
                        try Task.checkCancellation()
                        return .reused(url: url, track: track)
                    }
                }
            }
            var track = try await metadataReader.track(for: url)
            try Task.checkCancellation()
            track.path = canonicalPath
            if let identity = CatalogResourceIdentity(url: url) {
                track.fileResourceIdentifier = identity.resourceIdentifier
                track.fileVolumeIdentifier = identity.volumeIdentifier
            }
            return .loaded(url: url, track: track)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .failure(url: url, reason: LibraryScanDiagnostic.boundedReason(for: error))
        }
    }
}
