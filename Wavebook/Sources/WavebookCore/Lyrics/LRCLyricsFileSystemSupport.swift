import Foundation

enum LRCLyricsFileSystemError: Error {
    case cannotEnumerate(URL)
}

enum LRCLyricsFileSystemSupport {
    static let maximumCandidateCount = 256
    static let maximumDirectoryEntryCount = 4_096

    static func expectedSidecarURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("lrc")
    }

    static func matchingSidecars(
        in directory: URL,
        baseName: String,
        excluding excludedURL: URL? = nil,
        options: FileManager.DirectoryEnumerationOptions = [],
        requireRegularFile: Bool = false
    ) throws -> [URL] {
        var enumerationOptions = options
        enumerationOptions.insert(.skipsSubdirectoryDescendants)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey],
            options: enumerationOptions
        ) else {
            throw LRCLyricsFileSystemError.cannotEnumerate(directory)
        }

        let excludedPath = excludedURL?.standardizedFileURL.path
        var candidates: [URL] = []
        var entryCount = 0
        var hitEntryLimit = false
        while let object = enumerator.nextObject() {
            try Task.checkCancellation()
            entryCount += 1
            guard entryCount <= maximumDirectoryEntryCount else {
                hitEntryLimit = true
                break
            }
            guard let url = object as? URL,
                  url.pathExtension.caseInsensitiveCompare("lrc") == .orderedSame,
                  LRCLyrics.baseNameKey(forFileURL: url) == baseName,
                  url.standardizedFileURL.path != excludedPath else { continue }
            if requireRegularFile {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else { continue }
            }
            guard candidates.count < maximumCandidateCount else { return [] }
            insert(url, into: &candidates)
        }
        try Task.checkCancellation()
        return hitEntryLimit ? [] : candidates
    }

    private static func insert(_ url: URL, into candidates: inout [URL]) {
        guard maximumCandidateCount > 0 else { return }
        let index = candidates.firstIndex { comesBefore(url, $0) } ?? candidates.endIndex
        if candidates.count == maximumCandidateCount, index == candidates.endIndex { return }
        candidates.insert(url, at: index)
        if candidates.count > maximumCandidateCount {
            candidates.removeLast()
        }
    }

    private static func comesBefore(_ lhs: URL, _ rhs: URL) -> Bool {
        let comparison = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
        return comparison == .orderedSame ? lhs.path < rhs.path : comparison == .orderedAscending
    }
}
