import WavebookCore

struct SongListActions {
    var onPlay: ((Track) -> Void)?
    var contextMenuActions: TrackContextMenuActions
    var onPrefetchLyricsFileAvailability: (([Track]) -> Void)?
    var onRequestMore: (() -> Void)?

    init(
        onPlay: ((Track) -> Void)? = nil,
        contextMenuActions: TrackContextMenuActions = TrackContextMenuActions(),
        onPrefetchLyricsFileAvailability: (([Track]) -> Void)? = nil,
        onRequestMore: (() -> Void)? = nil
    ) {
        self.onPlay = onPlay
        self.contextMenuActions = contextMenuActions
        self.onPrefetchLyricsFileAvailability = onPrefetchLyricsFileAvailability
        self.onRequestMore = onRequestMore
    }
}
