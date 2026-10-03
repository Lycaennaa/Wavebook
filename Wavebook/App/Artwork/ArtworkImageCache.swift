import AppKit

@MainActor final class ArtworkImageCache {
    private let storage = NSCache<NSString, ArtworkCacheEntry>()

    init() {
        storage.countLimit = 512
        storage.totalCostLimit = 64 * 1_024 * 1_024
    }

    func entry(for key: String) -> ArtworkCacheEntry? {
        storage.object(forKey: key as NSString)
    }

    func image(for key: String) -> NSImage? {
        entry(for: key)?.image
    }

    func remove(for key: String) {
        storage.removeObject(forKey: key as NSString)
    }

    func store(image: NSImage?, fingerprint: String, for key: String) {
        storage.setObject(
            ArtworkCacheEntry(image: image, fingerprint: fingerprint),
            forKey: key as NSString,
            cost: image == nil ? 1 : 256 * 256 * 4
        )
    }
}

final class ArtworkCacheEntry: NSObject {
    let image: NSImage?
    let fingerprint: String

    init(image: NSImage?, fingerprint: String) {
        self.image = image
        self.fingerprint = fingerprint
    }
}
