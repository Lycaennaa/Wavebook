import Foundation
import WavebookCore

enum CatalogBenchmark {
    private static let trackCount = 2_000

    static func query() async throws -> PerformanceRun {
        try await benchmark(
            scenario: "catalog-query",
            description: "Track search and artist, album, and genre catalog pages",
            operations: 4
        ) { database in
            let tracksPage = try database.trackPage(matching: "Track 01999", limit: 24)
            let artistsPage = try database.artistPage(matching: "Artist", limit: 24)
            let albumsPage = try database.albumPage(matching: "Album", limit: 24)
            let genresPage = try database.genrePage(matching: "Genre", limit: 24)
            guard !tracksPage.tracks.isEmpty,
                  !artistsPage.items.isEmpty,
                  !albumsPage.items.isEmpty,
                  !genresPage.items.isEmpty else {
                throw PerformanceBenchmarkError.unexpectedResult("Catalog page query returned no results")
            }
        }
    }

    static func trackSearch() async throws -> PerformanceRun {
        try await benchmark(scenario: "catalog-track-search", description: "Search tracks in a 2,000-track catalog") { database in
            let tracks = try database.trackPage(matching: "Track 01999", limit: 24).tracks
            guard !tracks.isEmpty else {
                throw PerformanceBenchmarkError.unexpectedResult("Track search returned no results")
            }
        }
    }

    static func artistPage() async throws -> PerformanceRun {
        try await benchmark(scenario: "catalog-artist-page", description: "Load an artist page from a 2,000-track catalog") { database in
            let artists = try database.artistPage(matching: "Artist", limit: 24).items
            guard !artists.isEmpty else {
                throw PerformanceBenchmarkError.unexpectedResult("Artist page returned no results")
            }
        }
    }

    static func albumPage() async throws -> PerformanceRun {
        try await benchmark(scenario: "catalog-album-page", description: "Load an album page from a 2,000-track catalog") { database in
            let albums = try database.albumPage(matching: "Album", limit: 24).items
            guard !albums.isEmpty else {
                throw PerformanceBenchmarkError.unexpectedResult("Album page returned no results")
            }
        }
    }

    static func genrePage() async throws -> PerformanceRun {
        try await benchmark(scenario: "catalog-genre-page", description: "Load a genre page from a 2,000-track catalog") { database in
            let genres = try database.genrePage(matching: "Genre", limit: 24).items
            guard !genres.isEmpty else {
                throw PerformanceBenchmarkError.unexpectedResult("Genre page returned no results")
            }
        }
    }

    private static func benchmark(
        scenario: String,
        description: String,
        operations: Int = 1,
        query: @escaping (LibraryDatabase) throws -> Void
    ) async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: scenario,
            workload: PerformanceWorkload(
                description: description,
                operations: operations,
                dimensions: ["tracks": trackCount, "distinct_artists": 100, "distinct_albums": 250]
            ),
            prepare: {
                let fixtureRoot = try PerformanceFixtures.temporaryDirectory(named: scenario)
                let libraryRoot = fixtureRoot.appending(path: "Music")
                try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
                let database = try LibraryDatabase(path: fixtureRoot.appending(path: "Catalog.sqlite").path)
                let tracks = (0..<trackCount).map { index in
                    Track(
                        path: libraryRoot.appending(path: String(format: "Track-%05d.wav", index)).path,
                        title: String(format: "Track %05d", index),
                        artistDisplay: String(format: "Artist %03d", index % 100),
                        albumTitle: String(format: "Album %03d", index % 250),
                        albumArtist: String(format: "Artist %03d", index % 100),
                        genreDisplay: String(format: "Genre %02d", index % 12),
                        duration: 180,
                        format: "wav"
                    )
                }
                let savedTracks = try database.reconcile(rootPath: libraryRoot.path, tracks: tracks, lyricFiles: [])
                guard savedTracks.count == trackCount else {
                    throw PerformanceBenchmarkError.unexpectedResult("Catalog fixture did not seed every track")
                }

                return PerformancePreparedIteration(operation: {
                    try query(database)
                }, cleanup: {
                    try? FileManager.default.removeItem(at: fixtureRoot)
                })
            }
        )
    }
}

enum PlaybackQueueBenchmark {
    private static let trackCount = 5_000
    private static let navigationSteps = 10_000
    private static let shuffledTrackCount = 50_000
    private static let shuffledNavigationSteps = 1_000

    static func navigation() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "playback-queue",
            workload: PerformanceWorkload(
                description: "Construct a queue and navigate forward and backward",
                operations: navigationSteps * 2,
                dimensions: ["tracks": trackCount]
            ),
            prepare: {
                let tracks = (0..<trackCount).map { index in
                    Track(
                        path: "/synthetic-library/Track-\(index).wav",
                        title: "Track \(index)",
                        artistDisplay: "Benchmark Artist",
                        albumTitle: "Benchmark Album",
                        duration: 180,
                        format: "wav"
                    )
                }
                return PerformancePreparedIteration {
                    var queue = PlaybackQueue(items: tracks, currentIndex: 0)
                    queue.setRepeatMode(.all)
                    guard queue.play(at: 0) != nil else {
                        throw PerformanceBenchmarkError.unexpectedResult("Playback queue fixture was empty")
                    }
                    var checksum = 0
                    for _ in 0..<navigationSteps {
                        checksum += queue.next()?.title.utf8.count ?? 0
                    }
                    for _ in 0..<navigationSteps {
                        checksum += queue.previous()?.title.utf8.count ?? 0
                    }
                    guard checksum > 0 else {
                        throw PerformanceBenchmarkError.unexpectedResult("Playback queue navigation did no work")
                    }
                }
            }
        )
    }
    static func shuffledNavigation() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "playback-queue-shuffled-navigation",
            workload: PerformanceWorkload(
                description: "Navigate a shuffled 50,000-track queue and read current index",
                operations: shuffledNavigationSteps,
                dimensions: ["tracks": shuffledTrackCount]
            ),
            prepare: {
                let tracks = (0..<shuffledTrackCount).map { index in
                    Track(
                        path: "/synthetic-library/Track-\(index).wav",
                        title: "Track \(index)",
                        artistDisplay: "Benchmark Artist",
                        albumTitle: "Benchmark Album",
                        duration: 180,
                        format: "wav"
                    )
                }
                var queue = PlaybackQueue(items: tracks)
                queue.setShuffleEnabled(true)
                queue.setRepeatMode(.all)
                let startingQueueIndex = shuffledTrackCount / 2
                guard let entry = queue.entry(atQueueIndex: startingQueueIndex),
                      queue.play(entry) != nil,
                      queue.currentQueueIndex == startingQueueIndex else {
                    throw PerformanceBenchmarkError.unexpectedResult("Shuffled queue did not reach its starting index")
                }
                let startingQueue = queue
                return PerformancePreparedIteration {
                    var queue = startingQueue
                    var checksum = 0
                    for _ in 0..<shuffledNavigationSteps {
                        guard queue.next() != nil, let index = queue.currentQueueIndex else {
                            throw PerformanceBenchmarkError.unexpectedResult("Shuffled queue stopped during navigation")
                        }
                        checksum += index
                    }
                    guard checksum > 0 else {
                        throw PerformanceBenchmarkError.unexpectedResult("Shuffled queue navigation did no work")
                    }
                }
            }
        )
    }
}