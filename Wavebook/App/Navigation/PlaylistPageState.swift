import WavebookCore

enum PlaylistPageLoadedContent {
    case manual(items: [PlaylistItem], hasMore: Bool)
    case tracks(items: [Track], hasMore: Bool)

    var count: Int {
        switch self {
        case let .manual(items, _): return items.count
        case let .tracks(items, _): return items.count
        }
    }

    var hasMore: Bool {
        switch self {
        case let .manual(_, hasMore), let .tracks(_, hasMore): return hasMore
        }
    }

    var tracks: [Track] {
        switch self {
        case let .manual(items, _): return items.compactMap(\.track)
        case let .tracks(items, _): return items
        }
    }
    static func applying(
        _ page: PlaylistPageContent,
        to current: Self?,
        replacing: Bool
    ) -> (content: Self?, reachedItemLimit: Bool) {
        switch page {
        case let .manual(page):
            let currentItems: [PlaylistItem]?
            if let current, case let .manual(items, _) = current {
                currentItems = items
            } else {
                currentItems = nil
            }
            var accumulator = PlaylistPageAccumulator(items: currentItems ?? [])
            guard let reachedItemLimit = accumulator.apply(
                page,
                replacing: replacing,
                maximumRetainedItemCount: PlaybackQueue.maximumEntryCount
            ) else { return (current, false) }
            return (
                .manual(items: accumulator.items, hasMore: accumulator.hasMore),
                reachedItemLimit
            )
        case let .tracks(page):
            let currentItems: [Track]?
            if let current, case let .tracks(items, _) = current {
                currentItems = items
            } else {
                currentItems = nil
            }
            var accumulator = PlaylistPageAccumulator(items: currentItems ?? [])
            guard let reachedItemLimit = accumulator.apply(
                page,
                replacing: replacing,
                maximumRetainedItemCount: PlaybackQueue.maximumEntryCount
            ) else { return (current, false) }
            return (
                .tracks(items: accumulator.items, hasMore: accumulator.hasMore),
                reachedItemLimit
            )
        }
    }
}

extension PlaylistDestination {
    var isUser: Bool {
        if case .user = self { return true }
        return false
    }
}
