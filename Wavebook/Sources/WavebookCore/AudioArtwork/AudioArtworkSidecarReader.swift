import Foundation

enum AudioArtworkSidecarReader {
    static func artworkURL(for audioURL: URL) -> URL? {
        candidate(for: audioURL)?.url
    }

    static func artworkData(for audioURL: URL) -> Data? {
        candidate(for: audioURL)?.data
    }

    private static func candidate(for audioURL: URL) -> (url: URL, data: Data)? {
        guard !Task.isCancelled else { return nil }
        return candidate(in: candidateURLs(in: audioURL.deletingLastPathComponent().standardizedFileURL))
    }

    private static func candidate(in urls: [URL]) -> (url: URL, data: Data)? {
        for url in urls {
            guard !Task.isCancelled else { return nil }
            guard let data = AudioArtworkImageSupport.boundedArtworkData(at: url) else { continue }
            guard AudioArtworkImageSupport.isValidArtworkData(data) else { continue }
            guard !Task.isCancelled else { return nil }
            return (url, data)
        }
        return nil
    }

    static func cacheFingerprint(for audioURL: URL) -> String {
        guard !Task.isCancelled else { return "cancelled" }
        let directory = audioURL.deletingLastPathComponent().standardizedFileURL
        let candidates = candidateURLs(in: directory)
        guard !Task.isCancelled else { return "cancelled" }

        var candidateFingerprints: [String] = []
        for url in candidates {
            guard !Task.isCancelled else { return "cancelled" }
            candidateFingerprints.append("\(url.path):\(resourceFingerprint(for: url))")
        }

        let acceptedSidecarFingerprint: String
        if let acceptedCandidate = candidate(in: candidates) {
            guard let contentFingerprint = AudioArtworkImageSupport.contentFingerprint(
                for: acceptedCandidate.data
            ) else { return "cancelled" }
            acceptedSidecarFingerprint = "\(acceptedCandidate.url.path):\(contentFingerprint)"
        } else {
            acceptedSidecarFingerprint = "none"
        }
        guard !Task.isCancelled else { return "cancelled" }
        return [
            directory.path,
            resourceFingerprint(for: directory),
            candidateFingerprints.joined(separator: ";"),
            "accepted:\(acceptedSidecarFingerprint)"
        ].joined(separator: "|")
    }

    private static let maximumVisitedEntryCount = 4_096

    private static func candidateURLs(in directory: URL) -> [URL] {
        guard !Task.isCancelled else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var candidates: [URL] = []
        var visitedEntryCount = 0
        while visitedEntryCount < maximumVisitedEntryCount {
            guard !Task.isCancelled else { return [] }
            guard let object = enumerator.nextObject() else { break }
            visitedEntryCount += 1
            guard let url = object as? URL,
                  isSidecarCandidate(url),
                  url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { continue }
            insert(url, into: &candidates)
        }
        guard !Task.isCancelled else { return [] }
        return candidates
    }

    static func isSidecarCandidate(_ url: URL) -> Bool {
        AudioArtworkLimits.sidecarNames.contains(url.deletingPathExtension().lastPathComponent.lowercased()) &&
            AudioArtworkLimits.imageExtensions.contains(url.pathExtension.lowercased())
    }

    private static func insert(_ url: URL, into candidates: inout [URL]) {
        let maximumCount = AudioArtworkLimits.maximumSidecarCandidateCount
        guard maximumCount > 0 else { return }
        guard !candidates.contains(url) else { return }
        if candidates.count == maximumCount,
           !comesBefore(url, candidates[candidates.count - 1]) {
            return
        }
        let index = candidates.firstIndex { comesBefore(url, $0) } ?? candidates.endIndex
        candidates.insert(url, at: index)
        if candidates.count > maximumCount {
            candidates.removeLast()
        }
    }

    private static func comesBefore(_ lhs: URL, _ rhs: URL) -> Bool {
        let comparison = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
        return comparison == .orderedSame ? lhs.path < rhs.path : comparison == .orderedAscending
    }
    fileprivate static func resourceFingerprint(for url: URL) -> String {
        let currentURL = URL(fileURLWithPath: url.path)
        guard let values = try? currentURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isReadableKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .attributeModificationDateKey,
            .fileResourceIdentifierKey
        ]) else { return "missing" }
        return [
            String(values.isRegularFile == true),
            String(values.isReadable == true),
            String(values.fileSize ?? -1),
            String(values.contentModificationDate?.timeIntervalSince1970 ?? -1),
            String(values.attributeModificationDate?.timeIntervalSince1970 ?? -1),
            String(describing: values.fileResourceIdentifier)
        ].joined(separator: ",")
    }

    static func audioResourceFingerprint(for audioURL: URL) -> String {
        "\(audioURL.standardizedFileURL.path):\(resourceFingerprint(for: audioURL))"
    }
}
