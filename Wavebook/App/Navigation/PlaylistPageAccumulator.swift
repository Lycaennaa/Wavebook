import WavebookCore

struct PlaylistPageAccumulator<Item: Hashable & Sendable> {
    private(set) var items: [Item]
    private(set) var hasMore = false

    init(items: [Item] = []) {
        self.items = items
    }

    mutating func apply(
        _ page: LibraryCatalogPage<Item>,
        replacing: Bool,
        maximumRetainedItemCount: Int
    ) -> Bool? {
        if replacing || page.offset == 0 {
            items.removeAll(keepingCapacity: false)
        } else if page.offset != items.count {
            return nil
        }

        let availableCount = max(maximumRetainedItemCount - items.count, 0)
        let appendedCount = min(page.items.count, availableCount)
        items.reserveCapacity(items.count + appendedCount)
        items.append(contentsOf: page.items.prefix(appendedCount))

        let reachedLimit = appendedCount < page.items.count
        hasMore = page.hasMore && !reachedLimit
        return reachedLimit
    }
}
