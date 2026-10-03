import Foundation
@testable import WavebookCore
import XCTest

extension LRCLyricsTests {
    func testUniqueSiblingDirectoryLyricAssociatesWithTrack() async throws {
        let root = try makeRoot()
        let audioDirectory = root.appending(path: "Audio", directoryHint: .isDirectory)
        let lyricDirectory = root.appending(path: "Lyrics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lyricDirectory, withIntermediateDirectories: true)
        let audio = audioDirectory.appending(path: "Song.flac")
        let lyric = lyricDirectory.appending(path: "Song.lrc")
        try Data().write(to: audio)
        try "[00:00]Sibling".write(to: lyric, atomically: true, encoding: .utf8)

        let database = try LibraryDatabase(inMemory: true)
        try database.reconcile(
            rootPath: root.path,
            tracks: [
                Track(
                    path: audio.path,
                    title: "Song",
                    artistDisplay: "",
                    albumTitle: "",
                    genreDisplay: "",
                    duration: 0,
                    format: "flac"
                )
            ],
            lyricFiles: [lyric]
        )

        XCTAssertEqual(try database.lyricFiles(forTrackPath: audio.path), [LRCLyrics.canonicalFileURL(for: lyric)])
        let lyrics = try await LRCLyricsLoader().lyrics(for: audio, database: database)
        XCTAssertEqual(lyrics?.lines.first?.text, "Sibling")
    }
    func testReconcileManyLyricFilesPreservesAssociations() throws {
        let root = try makeRoot()
        let count = 1_024
        let tracks = (0..<count).map { index in
            Track(
                path: root.appending(path: "Audio/Track-\(index).flac").path,
                title: "Track-\(index)",
                artistDisplay: "",
                albumTitle: "",
                genreDisplay: "",
                duration: 0,
                format: "flac"
            )
        }
        let lyricFiles = (0..<count).map {
            root.appending(path: "Lyrics/Track-\($0).lrc")
        }

        let database = try LibraryDatabase(inMemory: true)
        try database.reconcile(rootPath: root.path, tracks: tracks, lyricFiles: lyricFiles)

        let cataloguedTracks = try database.tracks()
        XCTAssertEqual(cataloguedTracks.count, count)
        XCTAssertEqual(cataloguedTracks.filter(\.hasLyrics).count, count)
        XCTAssertEqual(try database.lyricFiles(forTrackPath: tracks[0].path).count, 1)
    }

    func testReconcileRejectsInputsPastBoundBeforeCreatingRoot() throws {
        let root = try makeRoot()
        let database = try LibraryDatabase(inMemory: true)
        let oversizedTracks = (0...LibraryDatabase.maximumReconciliationTrackCount).map { index in
            Track(
                path: root.appending(path: "Track-\(index).flac").path,
                title: "Track",
                artistDisplay: "",
                albumTitle: "",
                genreDisplay: "",
                duration: 0,
                format: "flac"
            )
        }
        XCTAssertThrowsError(try database.reconcile(rootPath: root.path, tracks: oversizedTracks, lyricFiles: []))
        XCTAssertTrue(try database.roots().isEmpty)

        let oversizedLyrics = (0...LibraryDatabase.maximumReconciliationLyricFileCount).map {
            root.appending(path: "Lyric-\($0).lrc")
        }
        XCTAssertThrowsError(try database.reconcile(rootPath: root.path, tracks: [], lyricFiles: oversizedLyrics))
        XCTAssertTrue(try database.roots().isEmpty)
    }

    func testReconcileCapsRepeatedBasenameCandidates() throws {
        let root = try makeRoot()
        let lyric = root.appending(path: "Lyrics/Song.lrc")
        let tracks = (0...LibraryDatabase.maximumLyricCandidateCount).map { index in
            Track(
                path: root.appending(path: "Audio-\(index)/Song.flac").path,
                title: "Song",
                artistDisplay: "",
                albumTitle: "",
                genreDisplay: "",
                duration: 0,
                format: "flac"
            )
        }
        let database = try LibraryDatabase(inMemory: true)

        try database.reconcile(rootPath: root.path, tracks: tracks, lyricFiles: [lyric])

        XCTAssertTrue(try database.tracks().allSatisfy { !$0.hasLyrics })
        XCTAssertEqual(try database.lyricFiles(forTrackPath: tracks[0].path), [])
    }

    func testLyricAssociationSQLCapsEachKeyAtDatabaseBoundary() throws {
        let root = try makeRoot()
        let lyric = root.appending(path: "Lyrics/Song.lrc")
        let tracks = (0...LibraryDatabase.maximumLyricCandidateCount).map { index in
            Track(
                path: root.appending(path: "Audio-\(index)/Song.flac").path,
                title: "Song",
                artistDisplay: "",
                albumTitle: "",
                genreDisplay: "",
                duration: 0,
                format: "flac"
            )
        }
        let database = try LibraryDatabase(inMemory: true)
        try database.reconcile(rootPath: root.path, tracks: tracks, lyricFiles: [])
        try database.registerLyricFile(lyric, forTrackPath: tracks[0].path)

        let capture = LyricAssociationQueryCapture()
        try LyricAssociationQueryTesting.$observer.withValue({ event in
            capture.append(event)
            }, operation: {
            try database.reconcile(rootPath: root.path, tracks: tracks, lyricFiles: [lyric])
            })

        let basenameQuery = try XCTUnwrap(capture.events(for: "lyricsBasename").first)
        let basename = LRCLyrics.baseNameKey(forFileURL: lyric)
        XCTAssertEqual(basenameQuery.candidateLimit, LibraryDatabase.maximumLyricCandidateCount + 1)
        XCTAssertEqual(basenameQuery.returnedCounts[basename], LibraryDatabase.maximumLyricCandidateCount + 1)
        XCTAssertTrue(basenameQuery.sql.contains("WITH RECURSIVE"))
        XCTAssertTrue(basenameQuery.sql.contains("INDEXED BY tracks_lyricsBasename"))
        XCTAssertTrue(basenameQuery.sql.contains("LIMIT 1"))
        XCTAssertTrue(basenameQuery.sql.contains("candidateRank < ?"))
        XCTAssertFalse(basenameQuery.sql.contains("ROW_NUMBER"))
        XCTAssertFalse(basenameQuery.sql.contains("LIKE"))
        XCTAssertTrue(basenameQuery.queryPlan.contains { $0.contains("tracks_lyricsBasename") })
        XCTAssertFalse(basenameQuery.queryPlan.contains { $0.contains("SCAN track") })

        let associationQuery = try XCTUnwrap(capture.events(for: "lyricsKey").first)
        let associationKey = LRCLyrics.associationKey(forFileURL: URL(fileURLWithPath: tracks[0].path))
        XCTAssertEqual(associationQuery.candidateLimit, LibraryDatabase.maximumLyricCandidateCount + 1)
        XCTAssertEqual(associationQuery.returnedCounts[associationKey], 1)
        XCTAssertTrue(associationQuery.sql.contains("INDEXED BY tracks_lyricsKey"))
        XCTAssertTrue(associationQuery.queryPlan.contains { $0.contains("tracks_lyricsKey") })
        XCTAssertFalse(associationQuery.queryPlan.contains { $0.contains("SCAN track") })
    }

    func testLyricAssociationCancellationRollsBackAfterBoundedQuery() throws {
        let root = try makeRoot()
        let track = Track(
            path: root.appending(path: "Song.flac").path,
            title: "Song",
            artistDisplay: "",
            albumTitle: "",
            genreDisplay: "",
            duration: 0,
            format: "flac"
        )
        let lyric = root.appending(path: "Song.lrc")
        let database = try LibraryDatabase(inMemory: true)
        try database.reconcile(rootPath: root.path, tracks: [track], lyricFiles: [])
        let token = LibraryDatabaseCancellationToken()

        XCTAssertThrowsError(
            try LyricAssociationQueryTesting.$observer.withValue({ _ in
                token.cancel()
            }, operation: {
                try LibraryDatabase.withCatalogCancellationToken(token) {
                    try database.reconcile(rootPath: root.path, tracks: [track], lyricFiles: [lyric])
                }
            })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try database.lyricFiles(forTrackPath: track.path), [])
    }

    func testLyricBasenameTreatsLikeMetacharactersLiterally() throws {
        let root = try makeRoot()
        let target = root.appending(path: "Audio/100%_Mix.flac")
        let decoy = root.appending(path: "Other/100XXMix.flac")
        let lyric = root.appending(path: "Lyrics/100%_Mix.lrc")
        let tracks = [
            Track(
                path: target.path,
                title: "Target",
                artistDisplay: "",
                albumTitle: "",
                genreDisplay: "",
                duration: 0,
                format: "flac"
            ),
            Track(
                path: decoy.path,
                title: "Decoy",
                artistDisplay: "",
                albumTitle: "",
                genreDisplay: "",
                duration: 0,
                format: "flac"
            )
        ]

        let database = try LibraryDatabase(inMemory: true)
        try database.reconcile(rootPath: root.path, tracks: tracks, lyricFiles: [lyric])

        XCTAssertEqual(try database.lyricFiles(forTrackPath: target.path), [LRCLyrics.canonicalFileURL(for: lyric)])
        XCTAssertEqual(try database.lyricFiles(forTrackPath: decoy.path), [])
    }

    func testIndexedLyricsDoNotCrossLoadDirectories() async throws {
        let root = try makeRoot()
        let firstDirectory = root.appending(path: "A", directoryHint: .isDirectory)
        let secondDirectory = root.appending(path: "B", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appending(path: "Song.flac")
        let second = secondDirectory.appending(path: "Song.flac")
        let lyric = secondDirectory.appending(path: "Song.lrc")
        try Data().write(to: first)
        try Data().write(to: second)
        try "[00:00]Right directory".write(to: lyric, atomically: true, encoding: .utf8)

        let database = try LibraryDatabase(inMemory: true)
        try database.reconcile(
            rootPath: root.path,
            tracks: [
                Track(
                    path: first.path,
                    title: "Song",
                    artistDisplay: "",
                    albumTitle: "",
                    genreDisplay: "",
                    duration: 0,
                    format: "flac"
                ),
                Track(
                    path: second.path,
                    title: "Song",
                    artistDisplay: "",
                    albumTitle: "",
                    genreDisplay: "",
                    duration: 0,
                    format: "flac"
                )
            ],
            lyricFiles: [lyric]
        )

        let tracks = try database.tracks()
        XCTAssertFalse(try XCTUnwrap(tracks.first { $0.path == first.path }).hasLyrics)
        XCTAssertTrue(try XCTUnwrap(tracks.first { $0.path == second.path }).hasLyrics)
        let loader = LRCLyricsLoader()
        let firstLyrics = try await loader.lyrics(for: first, database: database)
        let secondLyrics = try await loader.lyrics(for: second, database: database)
        XCTAssertNil(firstLyrics)
        XCTAssertEqual(secondLyrics?.lines.first?.text, "Right directory")
    }

    func testAmbiguousIndexedBasenameIsRejected() async throws {
        let root = try makeRoot()
        let firstDirectory = root.appending(path: "A", directoryHint: .isDirectory)
        let secondDirectory = root.appending(path: "B", directoryHint: .isDirectory)
        let lyricDirectory = root.appending(path: "Lyrics", directoryHint: .isDirectory)
        for directory in [firstDirectory, secondDirectory, lyricDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let first = firstDirectory.appending(path: "Song.flac")
        let second = secondDirectory.appending(path: "Song.flac")
        let lyric = lyricDirectory.appending(path: "Song.lrc")
        try Data().write(to: first)
        try Data().write(to: second)
        try "[00:00]Ambiguous".write(to: lyric, atomically: true, encoding: .utf8)

        let database = try LibraryDatabase(inMemory: true)
        try database.reconcile(
            rootPath: root.path,
            tracks: [
                Track(
                    path: first.path,
                    title: "Song",
                    artistDisplay: "",
                    albumTitle: "",
                    genreDisplay: "",
                    duration: 0,
                    format: "flac"
                ),
                Track(
                    path: second.path,
                    title: "Song",
                    artistDisplay: "",
                    albumTitle: "",
                    genreDisplay: "",
                    duration: 0,
                    format: "flac"
                )
            ],
            lyricFiles: [lyric]
        )

        XCTAssertTrue(try database.tracks().allSatisfy { !$0.hasLyrics })
        let loader = LRCLyricsLoader()
        let firstLyrics = try await loader.lyrics(for: first, database: database)
        let secondLyrics = try await loader.lyrics(for: second, database: database)
        XCTAssertNil(firstLyrics)
        XCTAssertNil(secondLyrics)
    }

    func testAmbiguousBasenameAcrossRootsIsRejected() async throws {
        let firstRoot = try makeRoot()
        let secondRoot = try makeRoot()
        let lyricRoot = try makeRoot()
        let first = firstRoot.appending(path: "Song.flac")
        let second = secondRoot.appending(path: "Song.flac")
        let lyric = lyricRoot.appending(path: "Song.lrc")
        try Data().write(to: first)
        try Data().write(to: second)
        try "[00:00]Ambiguous".write(to: lyric, atomically: true, encoding: .utf8)

        let database = try LibraryDatabase(inMemory: true)
        try database.reconcile(
            rootPath: firstRoot.path,
            tracks: [
                Track(
                    path: first.path,
                    title: "Song",
                    artistDisplay: "",
                    albumTitle: "",
                    genreDisplay: "",
                    duration: 0,
                    format: "flac"
                )
            ],
            lyricFiles: []
        )
        try database.reconcile(
            rootPath: secondRoot.path,
            tracks: [
                Track(
                    path: second.path,
                    title: "Song",
                    artistDisplay: "",
                    albumTitle: "",
                    genreDisplay: "",
                    duration: 0,
                    format: "flac"
                )
            ],
            lyricFiles: []
        )
        try database.reconcile(rootPath: lyricRoot.path, tracks: [], lyricFiles: [lyric])

        XCTAssertTrue(try database.tracks().allSatisfy { !$0.hasLyrics })
        let loader = LRCLyricsLoader()
        let firstLyrics = try await loader.lyrics(for: first, database: database)
        let secondLyrics = try await loader.lyrics(for: second, database: database)
        XCTAssertNil(firstLyrics)
        XCTAssertNil(secondLyrics)
    }

    func testDeletedSiblingLyricStaysAbsentAfterReopen() async throws {
        let root = try makeRoot()
        let audioDirectory = root.appending(path: "Audio", directoryHint: .isDirectory)
        let lyricDirectory = root.appending(path: "Lyrics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lyricDirectory, withIntermediateDirectories: true)
        let audio = audioDirectory.appending(path: "Song.flac")
        let lyric = lyricDirectory.appending(path: "Song.lrc")
        let track = Track(
            path: audio.path,
            title: "Song",
            artistDisplay: "",
            albumTitle: "",
            genreDisplay: "",
            duration: 0,
            format: "flac"
        )
        try Data().write(to: audio)
        try "[00:00]Sibling".write(to: lyric, atomically: true, encoding: .utf8)

        let databaseURL = root.appending(path: "Library.sqlite")
        do {
            let database = try LibraryDatabase(path: databaseURL.path)
            try database.reconcile(rootPath: root.path, tracks: [track], lyricFiles: [lyric])
            XCTAssertTrue(try XCTUnwrap(database.tracks().first).hasLyrics)
            let lyrics = try await LRCLyricsLoader().lyrics(for: audio, database: database)
            XCTAssertEqual(lyrics?.lines.first?.text, "Sibling")
        }

        try FileManager.default.removeItem(at: lyric)
        do {
            let database = try LibraryDatabase(path: databaseURL.path)
            try database.reconcile(rootPath: root.path, tracks: [track], lyricFiles: [])
            XCTAssertFalse(try XCTUnwrap(database.tracks().first).hasLyrics)
        }

        let reopened = try LibraryDatabase(path: databaseURL.path)
        XCTAssertFalse(try XCTUnwrap(reopened.tracks().first).hasLyrics)
        let lyrics = try await LRCLyricsLoader().lyrics(for: audio, database: reopened)
        XCTAssertNil(lyrics)
    }
    func testEmptyLyricScanClearsIndexedFiles() throws {
        let root = try makeRoot()
        let audio = root.appending(path: "Song.flac")
        let lyric = root.appending(path: "Song.lrc")
        try Data().write(to: audio)
        try "[00:00]Indexed".write(to: lyric, atomically: true, encoding: .utf8)

        let database = try LibraryDatabase(inMemory: true)
        let track = Track(
            path: audio.path,
            title: "Song",
            artistDisplay: "",
            albumTitle: "",
            genreDisplay: "",
            duration: 0,
            format: "flac"
        )
        try database.reconcile(rootPath: root.path, tracks: [track], lyricFiles: [lyric])
        XCTAssertEqual(try database.lyricFiles(forTrackPath: audio.path), [LRCLyrics.canonicalFileURL(for: lyric)])

        try database.reconcile(rootPath: root.path, tracks: [track], lyricFiles: [])

        XCTAssertFalse(try XCTUnwrap(database.tracks().first).hasLyrics)
        XCTAssertEqual(try database.lyricFiles(forTrackPath: audio.path), [])
    }
    func testLyricCandidateLimitRejectsOnePastBound() async throws {
        let root = try makeRoot()
        let audio = root.appending(path: "Song.flac")
        let candidatesDirectory = root.appending(path: "Candidates", directoryHint: .isDirectory)
        try Data().write(to: audio)
        try FileManager.default.createDirectory(at: candidatesDirectory, withIntermediateDirectories: false)

        let database = try LibraryDatabase(inMemory: true)
        let track = Track(
            path: audio.path,
            title: "Song",
            artistDisplay: "",
            albumTitle: "",
            genreDisplay: "",
            duration: 0,
            format: "flac"
        )
        try database.reconcile(rootPath: root.path, tracks: [track], lyricFiles: [])
        for index in 0...LibraryDatabase.maximumLyricCandidateCount {
            let lyricURL = candidatesDirectory.appending(path: "Candidate-\(index).lrc")
            try database.registerLyricFile(lyricURL, forTrackPath: audio.path)
        }

        XCTAssertEqual(try database.lyricFiles(forTrackPath: audio.path), [])
        let lyrics = try await LRCLyricsLoader().lyrics(for: audio, database: database)
        XCTAssertNil(lyrics)
    }

    func testIndexedLyricURLsUseRawPathTieBreak() throws {
        let root = try makeRoot()
        let audio = root.appending(path: "Song.flac")
        let track = Track(
            path: audio.path,
            title: "Song",
            artistDisplay: "",
            albumTitle: "",
            genreDisplay: "",
            duration: 0,
            format: "flac"
        )
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        _ = try database.save(track: track, rootID: rootID)

        let lowercase = root.appending(path: "song.lrc")
        let uppercase = root.appending(path: "Song.lrc")
        let key = LRCLyrics.associationKey(forFileURL: audio)
         try database.writer.write { database in
            for lyricURL in [lowercase, uppercase] {
                 try database.execute(
                    sql: "INSERT INTO lyricFiles (rootId, path, lyricsKey) VALUES (?, ?, ?)",
                    arguments: [rootID, lyricURL.path, key]
                )
            }
        }

        XCTAssertEqual(try database.lyricFiles(matchingKey: key), [uppercase, lowercase])
    }

}
