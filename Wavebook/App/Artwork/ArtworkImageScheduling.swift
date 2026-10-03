import Foundation

@MainActor final class ArtworkImageLoadQueue {
    private var keys: [String] = []

    var count: Int { keys.count }

    func enqueue(_ key: String) {
        guard !keys.contains(key) else { return }
        keys.append(key)
    }

    func dequeue() -> String? {
        guard !keys.isEmpty else { return nil }
        return keys.removeFirst()
    }

    @discardableResult
    func remove(_ key: String) -> Bool {
        guard let index = keys.firstIndex(of: key) else { return false }
        keys.remove(at: index)
        return true
    }
}

@MainActor final class ArtworkImageRetryQueue {
    struct Waiter {
        let id: UUID
        let request: ArtworkImageRequest
    }

    private var waiters: [UUID: ArtworkImageRequest] = [:]
    private var order: [UUID] = []

    var count: Int { waiters.count }
    var first: Waiter? {
        guard let id = order.first, let request = waiters[id] else { return nil }
        return Waiter(id: id, request: request)
    }

    func enqueue(id: UUID, request: ArtworkImageRequest) {
        guard waiters[id] == nil else { return }
        waiters[id] = request
        order.append(id)
    }

    func remove(id: UUID) {
        guard waiters.removeValue(forKey: id) != nil else { return }
        order.removeAll { $0 == id }
    }

    func contains(_ id: UUID) -> Bool {
        waiters[id] != nil
    }
}
