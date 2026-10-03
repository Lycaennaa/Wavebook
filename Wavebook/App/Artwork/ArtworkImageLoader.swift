import AppKit
import WavebookCore

@MainActor final class ArtworkImageLoader {
    static let shared = ArtworkImageLoader()

    private final class Load {
        let id: UUID
        let path: String
        var observers: [UUID: Observer]

        init(id: UUID, path: String, observer: Observer) {
            self.id = id
            self.path = path
            observers = [observer.id: observer]
        }
    }

    private final class Observer {
        let id: UUID
        weak var request: ArtworkImageRequest?
        let completion: (NSImage?) -> Void
        let shouldNotifyWhenUsingCachedImage: Bool

        init(
            id: UUID,
            request: ArtworkImageRequest,
            completion: @escaping (NSImage?) -> Void,
            shouldNotifyWhenUsingCachedImage: Bool
        ) {
            self.id = id
            self.request = request
            self.completion = completion
            self.shouldNotifyWhenUsingCachedImage = shouldNotifyWhenUsingCachedImage
        }
    }
    private enum CacheOutcome: Sendable {
        case useCached
        case read
        case readWithoutCaching
    }

    static let maximumActiveLoadCount = 2
    static let maximumQueuedLoadCount = 64
    private static let maximumRetryWaiterCount = 64

    private let reader = AudioArtworkReader()

    private let cache = ArtworkImageCache()
    private var loads: [String: Load] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let loadQueue = ArtworkImageLoadQueue()
    private var activeLoadCount = 0
    private let retryQueue = ArtworkImageRetryQueue()

    private init() {}

    func requestImage(
        forPath path: String,
        automaticallyRetry: Bool = true,
        completion: @escaping (NSImage?) -> Void
    ) -> ArtworkImageRequest {
        makeRequest(forPath: path, automaticallyRetry: automaticallyRetry, completion: completion)
    }

    private func makeRequest(
        forPath path: String,
        automaticallyRetry: Bool,
        completion: @escaping (NSImage?) -> Void
    ) -> ArtworkImageRequest {
        let key = cacheKey(forPath: path)
        let canAttachImmediately = loads[key] != nil || loadQueue.count < Self.maximumQueuedLoadCount
        let cachedEntry = canAttachImmediately ? cache.entry(for: key) : nil
        let request = ArtworkImageRequest(
            image: canAttachImmediately ? cachedEntry?.image : nil,
            state: canAttachImmediately && cachedEntry != nil ? .cached : .queued
        )
        return enqueueRequest(
            request: request,
            key: key,
            state: canAttachImmediately && cachedEntry != nil ? .cached : .queued,
            automaticallyRetry: automaticallyRetry,
            completion: completion
        )
    }

    private func enqueueRequest(
        request: ArtworkImageRequest,
        key: String,
        state: ArtworkImageRequest.State,
        automaticallyRetry: Bool,
        completion: @escaping (NSImage?) -> Void
    ) -> ArtworkImageRequest {
        if loads[key] != nil || loadQueue.count < Self.maximumQueuedLoadCount {
            attach(request: request, path: key, key: key, state: state, completion: completion)
            return request
        }

        guard automaticallyRetry, retryQueue.count < Self.maximumRetryWaiterCount else {
            request.complete(with: request.image)
            completion(request.image)
            return request
        }

        let waiterID = UUID()
        request.setCancellation({ [weak self] in
            self?.removeRetryWaiter(id: waiterID)
        }, state: .capacityLimited)
        request.setRetryHandler { [weak self, weak request] in
            guard let self, let request else { return }
            self.retry(request: request, path: key, key: key, waiterID: waiterID, completion: completion)
        }
        enqueueRetryWaiter(id: waiterID, request: request)
        return request

    }

    private func attach(
        request: ArtworkImageRequest,
        path: String,
        key: String,
        state: ArtworkImageRequest.State,
        completion: @escaping (NSImage?) -> Void
    ) {
        let observerID = UUID()
        request.setCancellation({ [weak self] in
            self?.cancel(key: key, observerID: observerID)
        }, state: state)
        let observer = Observer(
            id: observerID,
            request: request,
            completion: completion,
            shouldNotifyWhenUsingCachedImage: state != .cached
        )
        if let load = loads[key] {
            load.observers[observerID] = observer
            return
        }

        let load = Load(id: UUID(), path: path, observer: observer)
        loads[key] = load
        loadQueue.enqueue(key)
        startQueuedLoads()
    }

    private func retry(
        request: ArtworkImageRequest,
        path: String,
        key: String,
        waiterID: UUID,
        completion: @escaping (NSImage?) -> Void
    ) {
        guard !request.isCancelled, request.isCapacityLimited else { return }
        guard loadQueue.count < Self.maximumQueuedLoadCount || loads[key] != nil else { return }
        removeRetryWaiter(id: waiterID)
        attach(request: request, path: path, key: key, state: .queued, completion: completion)

    }

    private func retryWaitingRequests() {
        while let waiter = retryQueue.first, loadQueue.count < Self.maximumQueuedLoadCount {
            guard waiter.request.isCapacityLimited else {
                removeRetryWaiter(id: waiter.id)
                continue
            }
            waiter.request.retry()
            guard !retryQueue.contains(waiter.id) else { return }
        }
    }

    private func enqueueRetryWaiter(id: UUID, request: ArtworkImageRequest) {
        retryQueue.enqueue(id: id, request: request)
    }

    private func removeRetryWaiter(id: UUID) {
        retryQueue.remove(id: id)
    }

    private func startQueuedLoads() {
        while activeLoadCount < Self.maximumActiveLoadCount, let key = loadQueue.dequeue() {
            guard let load = loads[key] else { continue }
            activeLoadCount += 1
            tasks[load.id] = makeLoadTask(id: load.id, key: key, path: load.path)
        }
    }

    private func makeLoadTask(id: UUID, key: String, path: String) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [reader] in
            defer {
                Task { @MainActor in
                    ArtworkImageLoader.shared.finishCancelled(id: id, key: key)
                }
            }
            let url = URL(fileURLWithPath: path)
            for attempt in 0..<2 {
                guard !Task.isCancelled else { return }
                if await Self.performLoadAttempt(reader: reader, url: url, id: id, key: key, attempt: attempt) {
                    return
                }
            }
        }
    }

    private nonisolated static func performLoadAttempt(
        reader: AudioArtworkReader,
        url: URL,
        id: UUID,
        key: String,
        attempt: Int
    ) async -> Bool {
        let fingerprint = reader.artworkCacheFingerprint(for: url)
        guard !Task.isCancelled, fingerprint != "cancelled" else { return true }
        let outcome = await ArtworkImageLoader.shared.cacheOutcome(id: id, key: key, fingerprint: fingerprint)
        guard !Task.isCancelled, let outcome else { return true }
        switch outcome {
        case .useCached:
            await ArtworkImageLoader.shared.finish(
                id: id,
                key: key,
                fingerprint: fingerprint,
                image: nil,
                outcome: outcome
            )
            return true
        case .read, .readWithoutCaching:
            break
        }

        let image: CGImage?
        do {
            let data = await reader.artworkData(for: url)
            guard !Task.isCancelled else { return true }
            image = data.flatMap(Self.downsample)
        }
        let finalFingerprint = reader.artworkCacheFingerprint(for: url)
        guard !Task.isCancelled, finalFingerprint != "cancelled" else { return true }
        if fingerprint != finalFingerprint {
            guard attempt > 0 else { return false }
            await ArtworkImageLoader.shared.finish(
                id: id,
                key: key,
                fingerprint: finalFingerprint,
                image: nil,
                outcome: .readWithoutCaching
            )
            return true
        }
        await ArtworkImageLoader.shared.finish(
            id: id,
            key: key,
            fingerprint: finalFingerprint,
            image: image,
            outcome: .read
        )
        return true
    }

    private func cacheOutcome(id: UUID, key: String, fingerprint: String) -> CacheOutcome? {
        guard let load = loads[key], load.id == id, !load.observers.isEmpty else { return nil }
        guard let entry = cache.entry(for: key) else { return .read }
        guard entry.fingerprint == fingerprint else {
            cache.remove(for: key)
            let observers = Array(load.observers.values)
            observers.forEach { observer in
                guard let request = observer.request, !request.isCancelled else { return }
                request.beginLoading()
                if entry.image != nil {
                    observer.completion(nil)
                }
            }
            return .read
        }
        return .useCached
    }

    private func finish(
        id: UUID,
        key: String,
        fingerprint: String,
        image: CGImage?,
        outcome: CacheOutcome
    ) {
        activeLoadCount = max(activeLoadCount - 1, 0)
        let taskWasCancelled = tasks[id]?.isCancelled == true
        tasks.removeValue(forKey: id)
        guard let load = loads[key], load.id == id else {
            startQueuedLoads()
            retryWaitingRequests()
            return
        }

        loads.removeValue(forKey: key)
        guard !taskWasCancelled else {
            startQueuedLoads()
            retryWaitingRequests()
            return
        }

        let artwork: NSImage?
        switch outcome {
        case .useCached:
            artwork = cache.image(for: key)
        case .read:
            artwork = image.map { NSImage(cgImage: $0, size: .zero) }
            cache.store(image: artwork, fingerprint: fingerprint, for: key)
        case .readWithoutCaching:
            artwork = image.map { NSImage(cgImage: $0, size: .zero) }
            cache.remove(for: key)
        }

        startQueuedLoads()
        retryWaitingRequests()
        let observers = Array(load.observers.values)
        observers.forEach { observer in
            guard let request = observer.request, !request.isCancelled else { return }
            switch outcome {
            case .useCached:
                request.markCached(artwork)
                if observer.shouldNotifyWhenUsingCachedImage {
                    observer.completion(artwork)
                }
            case .read, .readWithoutCaching:
                request.complete(with: artwork)
                observer.completion(artwork)
            }
        }
    }
    private func finishCancelled(id: UUID, key: String) {
        guard tasks.removeValue(forKey: id) != nil else { return }
        activeLoadCount = max(activeLoadCount - 1, 0)
        guard let load = loads[key], load.id == id else {
            startQueuedLoads()
            retryWaitingRequests()
            return
        }
        loads.removeValue(forKey: key)
        startQueuedLoads()
        retryWaitingRequests()
    }

    private func cancel(key: String, observerID: UUID) {
        guard let load = loads[key], load.observers.removeValue(forKey: observerID) != nil else { return }
        guard load.observers.isEmpty else { return }

        loads.removeValue(forKey: key)
        if !loadQueue.remove(key) {
            tasks[load.id]?.cancel()
        }
        retryWaitingRequests()
    }

    private func cacheKey(forPath path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private nonisolated static func downsample(_ data: Data) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return AudioArtworkReader.decodedArtworkImage(data, maximumPixelSize: 256)
    }
}
