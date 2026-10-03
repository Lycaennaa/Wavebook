import AppKit
@MainActor final class ArtworkImageRequest {
    enum State {
        case cached
        case queued
        case capacityLimited
        case finished
        case cancelled
    }

    private(set) var image: NSImage?
    private var cancellation: (() -> Void)?
    private var retryHandler: (() -> Void)?
    private(set) var state: State
    private(set) var isCancelled = false

    var isCapacityLimited: Bool { state == .capacityLimited }

    init(image: NSImage?, state: State, cancellation: (() -> Void)? = nil) {
        self.image = image
        self.state = state
        self.cancellation = cancellation
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let cancellation = self.cancellation
        self.cancellation = nil
        retryHandler = nil
        state = .cancelled
        cancellation?()
    }

    func retry() {
        guard !isCancelled, isCapacityLimited else { return }
        retryHandler?()
    }

    func setCancellation(_ cancellation: @escaping () -> Void, state: State = .queued) {
        self.cancellation = cancellation
        retryHandler = nil
        self.state = state
    }

    func setRetryHandler(_ retryHandler: @escaping () -> Void) {
        self.retryHandler = retryHandler
        state = .capacityLimited
    }

    func markCached(_ image: NSImage?) {
        self.image = image
        retryHandler = nil
        state = .cached
    }
    func beginLoading() {
        image = nil
        retryHandler = nil
        state = .queued
    }

    func complete(with image: NSImage?) {
        self.image = image
        cancellation = nil
        retryHandler = nil
        state = .finished
    }
}
