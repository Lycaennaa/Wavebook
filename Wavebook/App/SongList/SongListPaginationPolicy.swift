import Foundation

enum SongListPaginationPolicy {
    nonisolated static func shouldRequestMore(
        hasMore: Bool,
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        visibleMaxY: CGFloat
    ) -> Bool {
        guard hasMore, documentHeight > 0, viewportHeight > 0 else { return false }
        let threshold = max(documentHeight - viewportHeight - 320, 0)
        return visibleMaxY >= threshold
    }
}
