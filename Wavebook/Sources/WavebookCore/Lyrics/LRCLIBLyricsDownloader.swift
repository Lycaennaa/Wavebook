import Foundation

/// Downloaded lyrics and their destination file.
public struct LRCLIBLyricsDownload: Sendable {
    /// URL where lyrics were stored.
    public let fileURL: URL
    /// Parsed lyrics.
    public let lyrics: LRCLyrics

    /// Creates a downloaded-lyrics result.
    public init(fileURL: URL, lyrics: LRCLyrics) {
        self.fileURL = fileURL
        self.lyrics = lyrics
    }
}

/// Metadata used to search LRCLIB.
public struct LRCLIBLyricsSearchQuery: Sendable {
    /// Track title query.
    public var trackName: String?
    /// Artist query.
    public var artistName: String?
    /// Album query.
    public var albumName: String?
    /// Additional free-text query.
    public var keywords: String?

    /// Creates a search query.
    public init(
        trackName: String? = nil,
        artistName: String? = nil,
        albumName: String? = nil,
        keywords: String? = nil
    ) {
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.keywords = keywords
    }
}

/// A lyric result returned by LRCLIB.
public struct LRCLIBLyricsSearchResult: Identifiable, Sendable {
    /// LRCLIB result identifier.
    public let id: Int64
    /// Track title returned by LRCLIB.
    public let trackName: String
    /// Artist name returned by LRCLIB.
    public let artistName: String
    /// Album name returned by LRCLIB.
    public let albumName: String
    /// Track duration, if supplied.
    public let duration: TimeInterval?
    /// Whether LRCLIB marks the track instrumental.
    public let isInstrumental: Bool
    /// Whether synchronized lyrics are available.
    public let hasSyncedLyrics: Bool
    /// Whether plain lyrics are available.
    public let hasPlainLyrics: Bool
    /// Parsed preview lyrics, if available.
    public let previewLyrics: LRCLyrics?
    fileprivate let response: LRCLIBResponse

    fileprivate init?(response: LRCLIBResponse) {
        guard let id = response.id else { return nil }
        self.id = id
        trackName = response.resolvedTrackName
        artistName = response.artistName ?? ""
        albumName = response.albumName ?? ""
        duration = response.duration.flatMap {
            $0.isFinite && $0 >= 0 && $0 <= Self.maximumDisplayDuration ? $0 : nil
        }
        let synced = response.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let plain = response.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let parsedSynced = synced.flatMap { try? LRCLyrics.parse($0) }
        let parsedPlain = plain.flatMap { try? LRCLyrics.parsePlain($0) }
        isInstrumental = response.instrumental == true
        hasSyncedLyrics = parsedSynced != nil
        hasPlainLyrics = parsedPlain != nil
        if isInstrumental {
            previewLyrics = LRCLyrics(
                lines: [LRCLyricLine(time: 0, text: "Instrumental")],
                isSynchronized: false,
                isInstrumental: true
            )
        } else {
            previewLyrics = parsedSynced ?? parsedPlain
        }
        self.response = response
    }

    private static let maximumDisplayDuration: TimeInterval = 7 * 24 * 60 * 60
}

/// Errors raised while downloading lyrics from LRCLIB.
public enum LRCLIBLyricsDownloadError: LocalizedError, Equatable, Sendable {
    /// Required track metadata was missing.
    case missingMetadata
    /// LRCLIB returned no matching lyrics.
    case notFound
    /// LRCLIB returned an invalid response.
    case invalidResponse
    /// Returned lyrics could not be parsed.
    case invalidLyrics
    /// The response exceeded the safe size limit.
    case responseTooLarge
    /// LRCLIB returned an HTTP error.
    case server(statusCode: Int, message: String?)
    /// LRCLIB redirected to an untrusted server.
    case untrustedRedirect

    /// Human-readable download error text.
    public var errorDescription: String? {
        switch self {
        case .missingMetadata:
            "Song title and artist are required to search LRCLIB."
        case .notFound:
            "Lyrics were not found on LRCLIB."
        case .invalidResponse:
            "LRCLIB returned an invalid response."
        case .invalidLyrics:
            "LRCLIB returned lyrics that could not be parsed."
        case .responseTooLarge:
            "LRCLIB returned more lyric data than the app can safely load."
        case let .server(statusCode, message):
            message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "LRCLIB request failed with status \(statusCode)."
        case .untrustedRedirect:
            "LRCLIB redirected the request to an untrusted server."
        }
    }
}

/// Downloads and stores lyrics from LRCLIB.
public actor LRCLIBLyricsDownloader {
    typealias HTTPRequest = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let performRequest: HTTPRequest

    /// Creates a downloader using an ephemeral URL session.
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: LRCLIBURLSessionDelegate(),
            delegateQueue: nil
        )
        performRequest = { request in
            try await Self.boundedData(for: request, session: session)
        }
    }

    init(performRequest: @escaping HTTPRequest) {
        self.performRequest = performRequest
    }

    /// Searches LRCLIB for lyric results.
    public func searchLyrics(_ query: LRCLIBLyricsSearchQuery) async throws -> [LRCLIBLyricsSearchResult] {
        let values = [query.trackName, query.artistName, query.albumName, query.keywords]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        guard !values.isEmpty else { throw LRCLIBLyricsDownloadError.missingMetadata }

        let queryItems = [
            query.trackName.map { URLQueryItem(name: "track_name", value: $0) },
            query.artistName.map { URLQueryItem(name: "artist_name", value: $0) },
            query.albumName.map { URLQueryItem(name: "album_name", value: $0) },
            query.keywords.map { URLQueryItem(name: "q", value: $0) }
        ].compactMap { item -> URLQueryItem? in
            guard let item,
                  item.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
            return item
        }

        let responses: [LRCLIBResponse] = try await request(
            path: "/api/search",
            queryItems: queryItems,
            as: [LRCLIBResponse].self
        ) ?? []
        let results = responses.prefix(Self.maximumSearchResultCount).compactMap(LRCLIBLyricsSearchResult.init)
        try Task.checkCancellation()
        return results
    }

    /// Downloads lyrics for a track by searching LRCLIB.
    public func downloadLyrics(
        _ result: LRCLIBLyricsSearchResult,
        for track: Track
    ) async throws -> LRCLIBLyricsDownload {
        try Task.checkCancellation()
        return try save(response: result.response, for: track)
    }

    /// Downloads lyrics for a track using a selected search result.
    public func downloadLyrics(for track: Track) async throws -> LRCLIBLyricsDownload {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artistDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else {
            throw LRCLIBLyricsDownloadError.missingMetadata
        }

        try Task.checkCancellation()
        let direct = try await directResult(for: track)
        if let direct, direct.instrumental == true {
            return try save(response: direct, for: track)
        }

        var payload = direct.flatMap(LyricsPayload.init)
        if payload?.isSynchronized != true {
            do {
                if let searched = try await bestSearchResult(for: track) {
                    payload = searched
                }
            } catch where payload != nil {
                // Keep LRCLIB's exact plain-lyrics result when optional synced fallback fails.
            }
        }

        guard let payload else { throw LRCLIBLyricsDownloadError.notFound }
        try Task.checkCancellation()

        return try save(payload: payload, for: track)
    }

    private func save(response: LRCLIBResponse, for track: Track) throws -> LRCLIBLyricsDownload {
        if response.instrumental == true {
            let lyrics = try LRCLyrics.parse(LRCLyrics.instrumentalSidecarMarker)
            return try write(source: LRCLyrics.instrumentalSidecarMarker, lyrics: lyrics, for: track)
        }

        if let synced = response.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            do {
                return try save(payload: LyricsPayload(text: synced, isSynchronized: true), for: track)
            } catch LRCLIBLyricsDownloadError.invalidLyrics {
                if let plain = response.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    return try save(payload: LyricsPayload(text: plain, isSynchronized: false), for: track)
                }
                throw LRCLIBLyricsDownloadError.invalidLyrics
            }
        }
        guard let plain = response.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            throw LRCLIBLyricsDownloadError.notFound
        }
        return try save(payload: LyricsPayload(text: plain, isSynchronized: false), for: track)
    }

    private func save(payload: LyricsPayload, for track: Track) throws -> LRCLIBLyricsDownload {
        let source: String
        let lyrics: LRCLyrics
        do {
            if payload.isSynchronized {
                source = payload.text
                lyrics = try LRCLyrics.parse(source)
            } else {
                source = "\(LRCLyrics.plainSidecarMarker)\n\(payload.text)"
                lyrics = try LRCLyrics.parsePlain(payload.text)
            }
        } catch {
            throw LRCLIBLyricsDownloadError.invalidLyrics
        }

        return try write(source: source, lyrics: lyrics, for: track)
    }

    private func write(source: String, lyrics: LRCLyrics, for track: Track) throws -> LRCLIBLyricsDownload {
        try Task.checkCancellation()
        let destination = try destinationURL(for: URL(fileURLWithPath: track.path))
        try Data(source.utf8).write(to: destination, options: .atomic)
        return LRCLIBLyricsDownload(fileURL: destination, lyrics: lyrics)
    }

    private func directResult(for track: Track) async throws -> LRCLIBResponse? {
        let response: LRCLIBResponse? = try await request(
            path: "/api/get",
            queryItems: [
                URLQueryItem(name: "artist_name", value: track.artistDisplay),
                URLQueryItem(name: "track_name", value: track.title),
                URLQueryItem(name: "album_name", value: track.albumTitle),
                URLQueryItem(name: "duration", value: Self.requestDuration(track.duration))
            ],
            as: LRCLIBResponse.self
        )
        guard let response, response.isPlausibleMatch(for: track) else { return nil }
        return response
    }

    private func bestSearchResult(for track: Track) async throws -> LyricsPayload? {
        let results: [LRCLIBResponse] = try await request(
            path: "/api/search",
            queryItems: [
                URLQueryItem(name: "track_name", value: track.title),
                URLQueryItem(name: "artist_name", value: track.artistDisplay)
            ],
            as: [LRCLIBResponse].self
        ) ?? []

        return results
            .compactMap { SearchMatch(response: $0, track: track) }
            .sorted(by: SearchMatch.isPreferred)
            .first?
            .payload
    }

    private func request<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        as type: Response.Type
    ) async throws -> Response? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else { throw LRCLIBLyricsDownloadError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await performRequest(request)
        try Task.checkCancellation()
        guard Self.isAllowedLRCLIBURL(response.url) else {
            throw LRCLIBLyricsDownloadError.untrustedRedirect
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw LRCLIBLyricsDownloadError.responseTooLarge
        }

        switch response.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(type, from: data)
            } catch {
                throw LRCLIBLyricsDownloadError.invalidResponse
            }
        case 404:
            return nil
        default:
            let message = (try? JSONDecoder().decode(LRCLIBErrorResponse.self, from: data))?.message
            throw LRCLIBLyricsDownloadError.server(statusCode: response.statusCode, message: message)
        }
    }

    private func destinationURL(for audioURL: URL) throws -> URL {
        let directory = audioURL.deletingLastPathComponent()
        let expected = LRCLyricsFileSystemSupport.expectedSidecarURL(for: audioURL)
        if let values = try? expected.resourceValues(forKeys: [.isRegularFileKey, .nameKey]),
           values.isRegularFile == true,
           values.name == expected.lastPathComponent {
            return expected
        }

        let candidates = try LRCLyricsFileSystemSupport.matchingSidecars(
            in: directory,
            baseName: LRCLyrics.baseNameKey(forFileURL: audioURL),
            excluding: expected,
            options: [.skipsHiddenFiles],
            requireRegularFile: true
        )
        return candidates.first ?? expected
    }

    private static func boundedData(
        for request: URLRequest,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw LRCLIBLyricsDownloadError.invalidResponse
        }
        if response.expectedContentLength > maximumResponseBytes {
            throw LRCLIBLyricsDownloadError.responseTooLarge
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maximumResponseBytes))
        }
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw LRCLIBLyricsDownloadError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, response)
    }

    fileprivate static func isAllowedLRCLIBURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "lrclib.net" || host.hasSuffix(".lrclib.net")
    }

    private static func requestDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration >= 0, duration <= 7 * 24 * 60 * 60 else { return "0" }
        return String(Int(duration.rounded()))
    }

    private static let maximumResponseBytes = 2 * 1_024 * 1_024
    private static let maximumSearchResultCount = 100
    private static let userAgent = "LRCGET v2.1.0 (https://github.com/tranxuanthang/lrcget)"
}

private struct LRCLIBResponse: Decodable, Sendable {
    let id: Int64?
    let name: String?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: TimeInterval?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    var resolvedTrackName: String { trackName?.nilIfEmpty ?? name?.nilIfEmpty ?? "" }

    func isPlausibleMatch(for track: Track) -> Bool {
        let responseTitle = SearchNormalizer.normalizedText(resolvedTrackName)
        guard !responseTitle.isEmpty,
              responseTitle == SearchNormalizer.normalizedText(track.title) else {
            return false
        }

        let responseArtist = SearchNormalizer.normalizedText(artistName ?? "")
        guard !responseArtist.isEmpty,
              responseArtist == SearchNormalizer.normalizedText(track.artistDisplay) else {
            return false
        }

        let responseAlbum = SearchNormalizer.normalizedText(albumName ?? "")
        let trackAlbum = SearchNormalizer.normalizedText(track.albumTitle)
        if !responseAlbum.isEmpty, !trackAlbum.isEmpty, responseAlbum != trackAlbum {
            return false
        }

        if track.duration > 0, let duration, abs(duration - track.duration) > 5 {
            return false
        }
        return true
    }
}

private struct LRCLIBErrorResponse: Decodable {
    let message: String?
}

private struct LyricsPayload: Sendable {
    let text: String
    let isSynchronized: Bool

    init(text: String, isSynchronized: Bool) {
        self.text = text
        self.isSynchronized = isSynchronized
    }

    init?(response: LRCLIBResponse) {
        if let synced = response.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            self.init(text: synced, isSynchronized: true)
        } else if let plain = response.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            self.init(text: plain, isSynchronized: false)
        } else {
            return nil
        }
    }
}

private struct SearchMatch {
    let payload: LyricsPayload
    let albumMatches: Bool
    let durationDifference: TimeInterval
    let id: Int64

    init?(response: LRCLIBResponse, track: Track) {
        guard let payload = LyricsPayload(response: response),
              SearchNormalizer.normalizedText(response.resolvedTrackName)
                  == SearchNormalizer.normalizedText(track.title),
              SearchNormalizer.normalizedText(response.artistName ?? "")
                  == SearchNormalizer.normalizedText(track.artistDisplay) else {
            return nil
        }

        let normalizedAlbum = SearchNormalizer.normalizedText(track.albumTitle)
        albumMatches = !normalizedAlbum.isEmpty
            && SearchNormalizer.normalizedText(response.albumName ?? "") == normalizedAlbum

        if track.duration > 0 {
            guard let duration = response.duration else { return nil }
            durationDifference = abs(duration - track.duration)
            guard durationDifference <= 5 else { return nil }
        } else {
            guard albumMatches else { return nil }
            durationDifference = 0
        }

        self.payload = payload
        id = response.id ?? .max
    }

    static func isPreferred(_ lhs: SearchMatch, _ rhs: SearchMatch) -> Bool {
        if lhs.payload.isSynchronized != rhs.payload.isSynchronized {
            return lhs.payload.isSynchronized
        }
        if lhs.albumMatches != rhs.albumMatches {
            return lhs.albumMatches
        }
        if lhs.durationDifference != rhs.durationDifference {
            return lhs.durationDifference < rhs.durationDifference
        }
        return lhs.id < rhs.id
    }
}

private final class LRCLIBURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(LRCLIBLyricsDownloader.isAllowedLRCLIBURL(request.url) ? request : nil)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
