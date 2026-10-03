import Foundation
@testable import WavebookCore
import XCTest

extension ListeningHistoryTests {
    func testPlayThresholdUsesKnownDurationAndThirtySecondCap() {
        XCTAssertEqual(ListeningPlayThreshold(openedDuration: 20).seconds, 10)
        XCTAssertEqual(ListeningPlayThreshold(openedDuration: 60).seconds, 30)
        XCTAssertEqual(ListeningPlayThreshold(openedDuration: 120).seconds, 30)
        XCTAssertTrue(ListeningPlayThreshold(openedDuration: 20).usesKnownDuration)
    }

    func testInvalidDurationUsesThirtySecondThreshold() {
        for duration in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
            let threshold = ListeningPlayThreshold(openedDuration: duration)
            XCTAssertEqual(threshold.seconds, 30)
            XCTAssertFalse(threshold.usesKnownDuration)
        }
    }

    func testPlayQualificationUsesInclusiveBoundaryAndOnlyQualifiesOnce() {
        var qualification = ListeningQualificationState(openedDuration: 60)

        XCTAssertFalse(qualification.update(actualListenedSeconds: 29.999))
        XCTAssertTrue(qualification.update(actualListenedSeconds: 30))
        XCTAssertTrue(qualification.didQualify)
        XCTAssertFalse(qualification.update(actualListenedSeconds: 31))
    }

    func testSkipQualificationRequiresExplicitDepartureAndFiveSeconds() {
        XCTAssertFalse(ListeningHistoryThresholds.qualifiesSkip(after: 4.999, endReason: .next))
        XCTAssertTrue(ListeningHistoryThresholds.qualifiesSkip(after: 5, endReason: .next))
        XCTAssertTrue(ListeningHistoryThresholds.qualifiesSkip(after: 5, endReason: .previous))
        XCTAssertTrue(ListeningHistoryThresholds.qualifiesSkip(after: 5, endReason: .differentTrackSelection))
        XCTAssertFalse(ListeningHistoryThresholds.qualifiesSkip(after: 5, endReason: .sameTrackRestart))
        XCTAssertFalse(ListeningHistoryThresholds.qualifiesSkip(after: 5, endReason: .naturalCompletion))
    }

    func testSnapshotTrimsAndDeduplicatesCreditsAndUsesAlbumOwnerFallback() throws {
        let track = Track(
            id: 42,
            path: "/Music/track.m4a",
            title: "  Song  ",
            artistDisplay: " Artist A ; Artist B, Artist A ",
            albumTitle: "  Album  ",
            albumArtist: nil,
            genreDisplay: " Rock ; Pop, Rock ",
            duration: 90,
            format: "m4a"
        )
        let snapshot = try XCTUnwrap(ListeningMediaSnapshot(
            liveTrackID: track.id,
            track: track,
            openedDuration: 90,
            openedFormat: "flac",
            createdAtUTC: Date(timeIntervalSince1970: 1)
        ))

        XCTAssertEqual(snapshot.title, "Song")
        XCTAssertEqual(snapshot.artists, ["Artist A", "Artist B"])
        XCTAssertEqual(snapshot.genres, ["Rock", "Pop"])
        XCTAssertEqual(snapshot.albumOwner, "Artist A")
        XCTAssertEqual(snapshot.albumKey, AlbumKey(title: "Album", owner: "Artist A"))
        XCTAssertEqual(snapshot.format, "flac")

        let changed = try XCTUnwrap(ListeningMediaSnapshot(
            liveTrackID: track.id,
            track: Track(
                id: track.id,
                path: track.path,
                title: track.title,
                artistDisplay: "Artist A; Artist C",
                albumTitle: track.albumTitle,
                albumArtist: track.albumArtist,
                genreDisplay: track.genreDisplay,
                duration: track.duration,
                format: track.format
            ),
            openedDuration: 90,
            openedFormat: "m4a",
            createdAtUTC: snapshot.createdAtUTC
        ))
        XCTAssertNotEqual(snapshot.metadataSignature, changed.metadataSignature)
    }

    func testSnapshotFallsBackToPathDerivedTitleAndExcludesBlankAlbum() throws {
        let snapshot = try XCTUnwrap(ListeningMediaSnapshot(
            liveTrackID: nil,
            track: Track(
                path: "/Music/Folder/  .mp3",
                title: "   ",
                artistDisplay: "Artist",
                albumTitle: "   ",
                genreDisplay: "",
                duration: 0,
                format: "mp3"
            ),
            openedDuration: .nan,
            openedFormat: "mp3",
            createdAtUTC: Date()
        ))

        XCTAssertEqual(snapshot.title, ".mp3")
        XCTAssertNil(snapshot.albumKey)
        XCTAssertTrue(snapshot.genres.isEmpty)
        XCTAssertEqual(snapshot.openedDuration, 0)
        XCTAssertNil(
            ListeningMediaSnapshot(
                liveTrackID: nil,
                title: "Song",
                artistDisplay: "",
                albumTitle: "",
                genreDisplay: "",
                openedDuration: 1,
                format: "mp3",
                createdAtUTC: Date(timeIntervalSinceReferenceDate: .nan)
            )
        )
    }
    func testSnapshotRejectsBlankTitleWithoutPathFallback() {
        XCTAssertNil(
            ListeningMediaSnapshot(
                liveTrackID: nil,
                title: "   ",
                artistDisplay: "Artist",
                albumTitle: "",
                genreDisplay: "",
                openedDuration: 1,
                format: "mp3",
                createdAtUTC: Date()
            )
        )
    }

    func testDecodedSnapshotNormalizesCreditLists() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": 1,
            "liveTrackID": 2,
            "title": " Song ",
            "artistDisplay": " Artist ",
            "albumTitle": "",
            "genreDisplay": " Genre ",
            "artists": [" Artist ", "Artist", " "],
            "genres": [" Genre ", "Genre"],
            "openedDuration": 10,
            "format": " mp3 ",
            "createdAtUTC": 0
        ])
        let snapshot = try JSONDecoder().decode(ListeningMediaSnapshot.self, from: data)

        XCTAssertEqual(snapshot.artists, ["Artist"])
        XCTAssertEqual(snapshot.genres, ["Genre"])
        XCTAssertEqual(snapshot.albumOwner, "Artist")
    }

    func testLocalDayValidatesProlepticGregorianBoundaries() throws {
        let leapDay = try XCTUnwrap(ListeningLocalDay("2024-02-29"))
        XCTAssertEqual(leapDay.year, 2024)
        XCTAssertNil(ListeningLocalDay("2023-02-29"))
        XCTAssertNil(ListeningLocalDay("2024-04-31"))
         XCTAssertEqual(try XCTUnwrap(ListeningLocalDay("2024-01-01")) < leapDay, true)
        XCTAssertNil(
            ListeningLocalDay(
                date: Date(timeIntervalSinceReferenceDate: .nan),
                 timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            )
        )
        XCTAssertEqual(
            ListeningLocalDay(
                date: Date(timeIntervalSince1970: -12_219_724_800),
                 timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            )?.rawValue,
            "1582-10-10"
        )
    }

    func testHeatmapBucketsUseExactFixedBoundaries() throws {
        let day = try XCTUnwrap(ListeningLocalDay("2024-01-01"))
        let expected: [(Int, ListeningHeatmapBucket)] = [
            (0, .zero),
            (1, .one),
            (2, .twoToThree),
            (3, .twoToThree),
            (4, .fourToSeven),
            (7, .fourToSeven),
            (8, .eightOrMore)
        ]

        for (count, bucket) in expected {
            XCTAssertEqual(ListeningHeatmapDay(day: day, qualifiedPlayCount: count).bucket, bucket)
        }
    }

}
