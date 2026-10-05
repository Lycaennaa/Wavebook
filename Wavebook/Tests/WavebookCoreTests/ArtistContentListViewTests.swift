import AppKit
import WavebookCore
import XCTest

@MainActor
final class ArtistContentListViewTests: XCTestCase {
    func testArtistAndAlbumContentPrefetchLyricsAvailability() {
        _ = NSApplication.shared
        let artistTracks = [makeTrack(1)]
        let albumTracks = [makeTrack(2)]
        var prefetchedBatches: [[Track]] = []
        let view = ArtistContentListView(frame: .zero)
        view.actions = SongListActions(
            onPrefetchLyricsFileAvailability: { prefetchedBatches.append($0) }
        )

        view.setContent(detail: nil, tracks: artistTracks)
        view.setAlbumContent(tracks: albumTracks)

        XCTAssertEqual(prefetchedBatches, [artistTracks, albumTracks])
    }

    private func makeTrack(_ id: Int) -> Track {
        Track(
            id: Int64(id),
            path: "/artist-content-tests/\(id).flac",
            title: "Track \(id)",
            artistDisplay: "Artist",
            albumTitle: "Album"
        )
    }
}
