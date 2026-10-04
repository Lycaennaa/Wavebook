import AppKit
import WavebookCore

final class LyricsPlaylistFilterControl: NSSegmentedControl {
    private(set) var filter: LyricsPlaylistFilter = .withLRC
    var onFilterChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        segmentCount = LyricsPlaylistFilter.allCases.count
        for filter in LyricsPlaylistFilter.allCases {
            setLabel(filter.displayName, forSegment: filter.rawValue)
        }
        trackingMode = .selectOne
        selectedSegment = filter.rawValue
        target = self
        action = #selector(filterChanged(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(for destination: PlaylistDestination) {
        isHidden = destination != .system(.lyrics)
    }

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        guard let filter = LyricsPlaylistFilter(rawValue: sender.selectedSegment),
              filter != self.filter else { return }
        self.filter = filter
        onFilterChange?()
    }
}
