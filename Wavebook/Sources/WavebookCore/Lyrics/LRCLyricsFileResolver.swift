import Foundation

struct LRCLyricsFileResolution {
    let url: URL
    let lyrics: LRCLyrics
}

enum LRCLyricsFileResolver {
    static func resolve(
        audioURL: URL,
        baseName: String,
        indexedURLs: [URL]
    ) throws -> LRCLyricsFileResolution? {
        try Task.checkCancellation()
        let candidates = indexedURLs.filter {
            $0.pathExtension.caseInsensitiveCompare("lrc") == .orderedSame
        }
        let sameDirectory = candidates.filter {
            LRCLyrics.sameDirectory($0, audioURL)
        }
        let otherDirectories = candidates.filter {
            !LRCLyrics.sameDirectory($0, audioURL)
        }

        var firstError: Error?
        if let resolution = try loadFirstValid(from: sameDirectory, firstError: &firstError) {
            try Task.checkCancellation()
            return resolution
        }

        do {
            if let resolution = try sidecarLyrics(for: audioURL, baseName: baseName) {
                try Task.checkCancellation()
                return resolution
            }
        } catch {
            if error is CancellationError { throw error }
            firstError = firstError ?? error
        }

        if let resolution = try loadFirstValid(from: otherDirectories, firstError: &firstError) {
            try Task.checkCancellation()
            return resolution
        }
        try Task.checkCancellation()
        if let firstError { throw firstError }
        return nil
    }

    private static func loadFirstValid(
        from urls: [URL],
        firstError: inout Error?
    ) throws -> LRCLyricsFileResolution? {
        for url in urls.prefix(LRCLyricsFileSystemSupport.maximumCandidateCount) {
            try Task.checkCancellation()
            do {
                let lyrics = try load(url)
                try Task.checkCancellation()
                return LRCLyricsFileResolution(url: url, lyrics: lyrics)
            } catch {
                if error is CancellationError { throw error }
                firstError = firstError ?? error
            }
        }
        try Task.checkCancellation()
        return nil
    }

    private static func sidecarLyrics(
        for audioURL: URL,
        baseName: String
    ) throws -> LRCLyricsFileResolution? {
        let directory = audioURL.deletingLastPathComponent()
        let expected = LRCLyricsFileSystemSupport.expectedSidecarURL(for: audioURL)
        var firstError: Error?

        if FileManager.default.fileExists(atPath: expected.path) {
            do {
                return LRCLyricsFileResolution(url: expected, lyrics: try load(expected))
            } catch {
                if error is CancellationError { throw error }
                firstError = normalizedSidecarError(error, directory: directory)
            }
        }

        do {
            let candidates = try LRCLyricsFileSystemSupport.matchingSidecars(
                in: directory,
                baseName: baseName,
                excluding: expected
            )
            for url in candidates {
                try Task.checkCancellation()
                do {
                    return LRCLyricsFileResolution(url: url, lyrics: try load(url))
                } catch {
                    if error is CancellationError { throw error }
                    firstError = firstError ?? normalizedSidecarError(error, directory: directory)
                }
            }
        } catch {
            if error is CancellationError { throw error }
            firstError = firstError ?? normalizedSidecarError(error, directory: directory)
        }

        if let firstError { throw firstError }
        return nil
    }

    private static func normalizedSidecarError(_ error: Error, directory: URL) -> Error {
        if error is LRCLyricsLoadError { return error }
        return LRCLyricsLoadError.unreadable(directory)
    }

    private static func load(_ url: URL) throws -> LRCLyrics {
        try Task.checkCancellation()
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey])
        } catch {
            if error is CancellationError { throw error }
            throw LRCLyricsLoadError.unreadable(url)
        }
        guard values.isRegularFile == true, values.isReadable != false, let size = values.fileSize, size > 0 else {
            throw LRCLyricsLoadError.unreadable(url)
        }
        guard size <= maximumFileBytes else { throw LRCLyricsLoadError.tooLarge(url) }

        let data = try readBoundedData(from: url)
        try Task.checkCancellation()

        guard let text = decode(data) else { throw LRCLyricsLoadError.invalidTextEncoding(url) }
        let lyrics: LRCLyrics
        do {
            lyrics = try LRCLyrics.parse(text)
        } catch {
            if error is CancellationError { throw error }
            throw LRCLyricsLoadError.invalidLyrics(url)
        }
        try Task.checkCancellation()
        return lyrics
    }

    private static func decode(_ data: Data) -> String? {
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1] {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        return nil
    }

    private static func readBoundedData(from url: URL) throws -> Data {
        let handle = try openLyricsFileHandle(for: url)
        var data = Data()
        var readError: Error?
        do {
            data = try readLyricsChunks(from: handle)
        } catch {
            readError = error
        }
        try closeLyricsFileHandle(handle, url: url, readError: readError)
        if let readError { throw readError }
        guard !data.isEmpty else { throw LRCLyricsLoadError.unreadable(url) }
        guard data.count <= maximumFileBytes else { throw LRCLyricsLoadError.tooLarge(url) }
        return data
    }

    private static func openLyricsFileHandle(for url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: url)
        } catch {
            if error is CancellationError { throw error }
            throw LRCLyricsLoadError.unreadable(url)
        }
    }

    private static func readLyricsChunks(from handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count <= maximumFileBytes {
            try Task.checkCancellation()
            let remaining = maximumFileBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        return data
    }

    private static func closeLyricsFileHandle(
        _ handle: FileHandle,
        url: URL,
        readError: Error?
    ) throws {
        do {
            try handle.close()
        } catch {
            if let readError, readError is CancellationError { throw readError }
            if error is CancellationError { throw error }
            throw LRCLyricsLoadError.unreadable(url)
        }
    }

    private static let maximumFileBytes = 2 * 1_024 * 1_024
}
