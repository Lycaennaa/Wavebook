import WavebookCore

enum PlaylistPageLoadedContent {
    case manual(items: [PlaylistItem], hasMore: Bool, totalCount: Int)
    case tracks(items: [Track], hasMore: Bool, totalCount: Int)

    var count: Int {
        switch self {
        case let .manual(items, _, _): return items.count
        case let .tracks(items, _, _): return items.count
        }
    }

    var totalCount: Int {
        switch self {
        case let .manual(_, _, totalCount), let .tracks(_, _, totalCount): return totalCount
        }
    }

    var hasMore: Bool {
        switch self {
        case let .manual(_, hasMore, _), let .tracks(_, hasMore, _): return hasMore
        }
    }

    var tracks: [Track] {
        switch self {
        case let .manual(items, _, _): return items.compactMap(\.track)
        case let .tracks(items, _, _): return items
        }
    }

    private static func resolvedTotalCount(
        pageTotalCount: Int?,
        currentTotalCount: Int?,
        offset: Int,
        pageItemCount: Int
    ) -> Int {
        pageTotalCount ?? currentTotalCount ?? (offset + pageItemCount)
    }

    static func applying(
        _ page: PlaylistPageContent,
        to current: Self?,
        replacing: Bool
    ) -> (content: Self?, reachedItemLimit: Bool) {
        switch page {
        case let .manual(page):
            let currentItems: [PlaylistItem]?
            if let current, case let .manual(items, _, _) = current {
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
            let currentTotalCount: Int?
            if let current, case let .manual(_, _, totalCount) = current {
                currentTotalCount = totalCount
            } else {
                currentTotalCount = nil
            }
            let totalCount = Self.resolvedTotalCount(
                pageTotalCount: page.totalCount,
                currentTotalCount: currentTotalCount,
                offset: page.offset,
                pageItemCount: page.items.count
            )
            return (
                .manual(items: accumulator.items, hasMore: accumulator.hasMore, totalCount: totalCount),
                reachedItemLimit
            )
        case let .tracks(page):
            let currentItems: [Track]?
            if let current, case let .tracks(items, _, _) = current {
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
            let currentTotalCount: Int?
            if let current, case let .tracks(_, _, totalCount) = current {
                currentTotalCount = totalCount
            } else {
                currentTotalCount = nil
            }
            let totalCount = Self.resolvedTotalCount(
                pageTotalCount: page.totalCount,
                currentTotalCount: currentTotalCount,
                offset: page.offset,
                pageItemCount: page.items.count
            )
            return (
                .tracks(items: accumulator.items, hasMore: accumulator.hasMore, totalCount: totalCount),
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
