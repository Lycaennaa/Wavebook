@testable import WavebookCore
import XCTest

final class MetadataParserTests: XCTestCase {
    func testSplitListUsesOnlyCommaAndSemicolon() {
        XCTAssertEqual(MetadataParser.splitList("One, Two; Three & Four / Five"), ["One", "Two", "Three & Four / Five"])
    }
    func testSplitListBoundsComponentCountAndLength() {
        let input = String(repeating: "x", count: 100_000) + ",Artist"
        let result = MetadataParser.splitList(input)

        XCTAssertEqual(result.count, 2)
        XCTAssertLessThanOrEqual(result[0].count, AudioMetadataLimits.maximumMetadataValueLength)
        XCTAssertLessThanOrEqual(result.reduce(0) { $0 + $1.count }, AudioMetadataLimits.maximumMergedValueLength)
    }

    func testTrackAlbumKeyUsesAlbumArtistThenFirstArtist() {
        let withAlbumArtist = Track(
            path: "a",
            title: "Song",
            artistDisplay: "Track Artist",
            albumTitle: "Album",
            albumArtist: "Album Artist",
            genreDisplay: "",
            duration: 1,
            format: "flac"
        )
        XCTAssertEqual(withAlbumArtist.albumKey, AlbumKey(title: "Album", owner: "Album Artist"))

        let fallback = Track(
            path: "b",
            title: "Song",
            artistDisplay: "One; Two",
            albumTitle: "Album",
            genreDisplay: "",
            duration: 1,
            format: "flac"
        )
        XCTAssertEqual(fallback.albumKey, AlbumKey(title: "Album", owner: "One"))
    }

    func testTrackExposesEveryArtistAndGenre() {
        let track = Track(
            path: "a",
            title: "Song",
            artistDisplay: "One; Two",
            albumTitle: "Album",
            genreDisplay: "Rock, Soul",
            duration: 1,
            format: "flac"
        )

        XCTAssertEqual(track.artists, ["One", "Two"])
        XCTAssertEqual(track.genres, ["Rock", "Soul"])
    }

    func testTrackUsesMetadataWithFilenameFallbacks() {
        let url = URL(fileURLWithPath: "/Music/Loose File.FLAC")
        let track = MetadataParser.track(
            for: url,
            duration: 123,
            tags: MetadataParser.ParsedTags(
                title: "  Tagged Title  ",
                artistDisplay: "Artist",
                albumTitle: "Album",
                albumArtist: "Album Artist",
                genreDisplay: "Genre"
            )
        )

        XCTAssertEqual(track.title, "Tagged Title")
        XCTAssertEqual(track.artistDisplay, "Artist")
        XCTAssertEqual(track.albumTitle, "Album")
        XCTAssertEqual(track.albumArtist, "Album Artist")
        XCTAssertEqual(track.genreDisplay, "Genre")
        XCTAssertEqual(track.duration, 123)
        XCTAssertEqual(track.format, "flac")

        XCTAssertEqual(MetadataParser.track(for: url, duration: .nan).title, "Loose File")
    }
}
