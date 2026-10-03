import AppKit
import WavebookCore

@MainActor
final class PlaybackArtworkController {
    private let loader: ArtworkImageLoader
    private var request: ArtworkImageRequest?
    private var generation: UUID?

    private(set) var image: NSImage?

    init(loader: ArtworkImageLoader = .shared) {
        self.loader = loader
    }

    func start(for track: Track, onChange: @escaping () -> Void) {
        cancel()
        let generation = UUID()
        self.generation = generation
        let request = loader.requestImage(forPath: track.path) { [weak self] image in
            guard let self, self.generation == generation else { return }
            self.image = image
            onChange()
        }
        self.request = request
        image = request.image
    }

    func cancel(keepingImage: Bool = false) {
        generation = nil
        request?.cancel()
        request = nil
        if !keepingImage {
            image = nil
        }
    }
}
