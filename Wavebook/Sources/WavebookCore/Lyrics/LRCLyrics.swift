import Foundation

private struct LRCTimedEntry {
    var time: TimeInterval
    let text: String
    let order: Int
}
/// A parsed lyric line with an optional timestamp.
public struct LRCLyricLine: Hashable, Sendable {
    /// Timestamp in seconds.
    public let time: TimeInterval
    /// Lyric text.
    public let text: String

    /// Creates a lyric line.
    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}

/// Parsed synchronized or plain lyrics.
public struct LRCLyrics: Hashable, Sendable {
    /// Lyric lines in playback order.
    public let lines: [LRCLyricLine]
    /// Whether timestamps synchronize the lines.
    public let isSynchronized: Bool
    /// Whether the source explicitly identifies the track as instrumental.
    public let isInstrumental: Bool

    /// Creates parsed lyrics.
    public init(
        lines: [LRCLyricLine],
        isSynchronized: Bool = true,
        isInstrumental: Bool = false
    ) {
        self.lines = lines
        self.isSynchronized = isSynchronized
        self.isInstrumental = isInstrumental
    }

    /// Parses synchronized LRC or instrumental lyrics.
    public static func parse(_ source: String) throws -> LRCLyrics {
        try Task.checkCancellation()
        if try containsLineMarker(source, marker: instrumentalSidecarMarker, caseInsensitive: true) {
            try Task.checkCancellation()
            return LRCLyrics(
                lines: [LRCLyricLine(time: 0, text: "Instrumental")],
                isSynchronized: false,
                isInstrumental: true
            )
        }

        var entries: [LRCTimedEntry] = []
        var lyricByteCount = 0
        var offset: TimeInterval = 0
        var order = 0
        for sourceLine in source.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline) {
            try parseLine(
                sourceLine,
                offset: &offset,
                entries: &entries,
                lyricByteCount: &lyricByteCount,
                order: &order
            )
        }

        if entries.isEmpty,
           try containsLineMarker(source, marker: plainSidecarMarker, caseInsensitive: false) {
            let plain = source
                .split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline)
                .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) != plainSidecarMarker }
                .joined(separator: "\n")
            return try parsePlain(plain)
        }
        try Task.checkCancellation()
        guard !entries.isEmpty else { throw LRCParseError.noTimedLyrics }
        for index in entries.indices {
            entries[index].time = max(0, entries[index].time + offset)
        }
        try Task.checkCancellation()
        entries.sort {
            if $0.time == $1.time { return $0.order < $1.order }
            return $0.time < $1.time
        }
        try Task.checkCancellation()
        let lines = try combinedLyricLines(entries: entries, lyricByteCount: &lyricByteCount)
        try Task.checkCancellation()
        let firstLineText = lines.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLines = firstLineText.map { $0.isEmpty || $0 == "♪" } == true
            ? Array(lines.dropFirst())
            : lines
        return LRCLyrics(lines: normalizedLines)
    }

    private static func parseLine(
        _ sourceLine: Substring,
        offset: inout TimeInterval,
        entries: inout [LRCTimedEntry],
        lyricByteCount: inout Int,
        order: inout Int
    ) throws {
        var remainder = String(sourceLine)
        var timestamps: [TimeInterval] = []
        while remainder.first == "[", let closingBracket = remainder.firstIndex(of: "]") {
            try Task.checkCancellation()
            let tokenStart = remainder.index(after: remainder.startIndex)
            let token = String(remainder[tokenStart..<closingBracket]).trimmingCharacters(in: CharacterSet.whitespaces)
            remainder = String(remainder[remainder.index(after: closingBracket)...])
            if token.lowercased().hasPrefix("offset:") {
                let value = token.dropFirst("offset:".count).trimmingCharacters(in: CharacterSet.whitespaces)
                if let milliseconds = Double(value), milliseconds.isFinite {
                    offset = milliseconds / 1_000
                }
            } else if let timestamp = parseTimestamp(token) {
                timestamps.append(timestamp)
            }
        }
        try Task.checkCancellation()
        guard !timestamps.isEmpty else { return }
        let text = remainder.trimmingCharacters(in: CharacterSet.whitespaces)
        let textByteCount = text.utf8.count
        for timestamp in timestamps {
            try Task.checkCancellation()
            guard entries.count < maximumLineCount else { throw LRCParseError.tooManyLines }
            try addLyricBytes(textByteCount, to: &lyricByteCount)
            entries.append(LRCTimedEntry(time: timestamp, text: text, order: order))
            order += 1
        }
    }

    private static func combinedLyricLines(
        entries: [LRCTimedEntry],
        lyricByteCount: inout Int
    ) throws -> [LRCLyricLine] {
        var lines: [LRCLyricLine] = []
        for entry in entries {
            try Task.checkCancellation()
            if let last = lines.last, last.time == entry.time {
                let combined: String
                if last.text.isEmpty {
                    combined = entry.text
                } else if entry.text.isEmpty {
                    combined = last.text
                } else {
                    try addLyricBytes(1, to: &lyricByteCount)
                    combined = "\(last.text)\n\(entry.text)"
                }
                lines[lines.count - 1] = LRCLyricLine(time: last.time, text: combined)
            } else {
                lines.append(LRCLyricLine(time: entry.time, text: entry.text))
            }
        }
        return lines
    }

    /// Parses plain-text lyrics without timestamps.
    public static func parsePlain(_ source: String) throws -> LRCLyrics {
        try Task.checkCancellation()
        var lines: [LRCLyricLine] = []
        var lyricByteCount = 0
        for sourceLine in source.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline) {
            try Task.checkCancellation()
            let text = String(sourceLine).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if lines.count >= maximumLineCount {
                try Task.checkCancellation()
                throw LRCParseError.tooManyLines
            }
            try addLyricBytes(text.utf8.count, to: &lyricByteCount)
            lines.append(LRCLyricLine(time: 0, text: text))
        }
        try Task.checkCancellation()
        guard !lines.isEmpty else { throw LRCParseError.noTimedLyrics }
        try Task.checkCancellation()
        return LRCLyrics(lines: lines, isSynchronized: false)
    }

    /// Returns the lyric line active at an elapsed playback time.
    public func lineIndex(at elapsed: TimeInterval, leadTime: TimeInterval = 0) -> Int? {
        guard isSynchronized, elapsed.isFinite, leadTime.isFinite, !lines.isEmpty else { return nil }
        let anticipatedElapsed = elapsed + max(0, leadTime)
        guard anticipatedElapsed.isFinite, anticipatedElapsed >= lines[0].time else { return nil }
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lines[middle].time <= anticipatedElapsed {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower - 1
    }

    private static func containsLineMarker(
        _ source: String,
        marker: String,
        caseInsensitive: Bool
    ) throws -> Bool {
        let normalizedMarker = marker.lowercased()
        for sourceLine in source.split(whereSeparator: \Character.isNewline) {
            try Task.checkCancellation()
            let line = String(sourceLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = caseInsensitive ? line.lowercased() == normalizedMarker : line == marker
            if matches { return true }
        }
        try Task.checkCancellation()
        return false
    }
    private static func addLyricBytes(_ bytes: Int, to total: inout Int) throws {
        try Task.checkCancellation()
        guard total <= maximumLyricByteCount,
              bytes <= maximumLyricByteCount - total else {
            throw LRCParseError.tooManyBytes
        }
        total += bytes
    }

    private static func parseTimestamp(_ token: String) -> TimeInterval? {
        let parts = token
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Int(parts[0]), minutes >= 0,
              let seconds = Double(parts[1]), seconds.isFinite, seconds >= 0, seconds < 60 else { return nil }
        return TimeInterval(minutes) * 60 + seconds
    }

    /// Returns the stable association key for a lyric sidecar URL.
    public static func matchKey(forFileURL url: URL) -> String {
        let standardizedURL = canonicalFileURL(for: url)
        return standardizedURL
            .deletingLastPathComponent()
            .appendingPathComponent(baseNameKey(forFileURL: standardizedURL))
            .path
    }

    static func canonicalFileURL(for url: URL) -> URL {
        URL(fileURLWithPath: LibraryDatabase.canonicalRootPath(url.standardizedFileURL.path))
    }

    static func baseNameKey(forFileURL url: URL) -> String {
        return canonicalFileURL(for: url)
            .deletingPathExtension()
            .lastPathComponent
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func associationKey(forFileURL url: URL) -> String {
        canonicalFileURL(for: url).path
    }

    static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalFileURL(for: lhs).deletingLastPathComponent().path
            == canonicalFileURL(for: rhs).deletingLastPathComponent().path
    }

    static let plainSidecarMarker = "[re:Wavebook LRCLIB plain]"
    static let instrumentalSidecarMarker = "[au: instrumental]"
    private static let maximumLineCount = 10_000
    private static let maximumLyricByteCount = 2 * 1_024 * 1_024
}

/// Errors raised while parsing synchronized lyrics.
public enum LRCParseError: Error, Equatable, Sendable {
    /// No timed lyric lines were found.
    case noTimedLyrics
    /// The source exceeded the line limit.
    case tooManyLines
    /// The source exceeded the byte limit.
    case tooManyBytes
}

/// Errors raised while loading lyrics from disk.
public enum LRCLyricsLoadError: LocalizedError, Sendable {
    /// The lyrics content was invalid.
    case invalidLyrics(URL)
    /// The lyrics file used an unsupported encoding.
    case invalidTextEncoding(URL)
    /// The library root was unavailable.
    case rootUnavailable(URL)
    /// The lyrics file exceeded the safe size limit.
    case tooLarge(URL)
    /// The lyrics file could not be read.
    case unreadable(URL)

    /// Human-readable loading error text.
    public var errorDescription: String? {
        switch self {
        case let .invalidLyrics(url): "No timed lyrics found in \(url.lastPathComponent)."
        case let .invalidTextEncoding(url): "Could not decode \(url.lastPathComponent)."
        case let .rootUnavailable(url): "Lyrics folder is unavailable: \(url.path)."
        case let .tooLarge(url): "Lyrics file is too large: \(url.lastPathComponent)."
        case let .unreadable(url): "Could not read lyrics file: \(url.path)."
        }
    }
}

/// Resolves lyrics from indexed files and sidecar candidates.
public actor LRCLyricsLoader {
    /// Creates an empty lyrics loader.
    public init() {}

    /// Loads lyrics associated with an audio URL.
    public func lyrics(for audioURL: URL, database: LibraryDatabase?) throws -> LRCLyrics? {
        try Task.checkCancellation()
        let resolution = try Self.resolve(audioURL: audioURL, database: database)
        try Task.checkCancellation()
        return resolution?.lyrics
    }

    /// Loads lyrics using configured library roots.
    public func lyrics(for audioURL: URL, libraryRoots _: [URL]) throws -> LRCLyrics? {
        try Task.checkCancellation()
        let resolution = try Self.resolve(audioURL: audioURL, indexedURLs: [])
        try Task.checkCancellation()
        return resolution?.lyrics
    }

    /// Returns the validated lyrics file selected for an audio URL.
    public func lyricFileURL(
        for audioURL: URL,
        database: LibraryDatabase?
    ) throws -> URL? {
        try Task.checkCancellation()
        let resolution = try Self.resolve(audioURL: audioURL, database: database)
        try Task.checkCancellation()
        return resolution?.url
    }
    private nonisolated static func resolve(
        audioURL: URL,
        database: LibraryDatabase?
    ) throws -> LRCLyricsFileResolution? {
        let indexedURLs = try database?.lyricFiles(forTrackPath: audioURL.path) ?? []
        return try resolve(audioURL: audioURL, indexedURLs: indexedURLs)
    }

    private nonisolated static func resolve(
        audioURL: URL,
        indexedURLs: [URL]
    ) throws -> LRCLyricsFileResolution? {
        try LRCLyricsFileResolver.resolve(
            audioURL: audioURL,
            baseName: LRCLyrics.baseNameKey(forFileURL: audioURL),
            indexedURLs: indexedURLs
        )
    }
}
