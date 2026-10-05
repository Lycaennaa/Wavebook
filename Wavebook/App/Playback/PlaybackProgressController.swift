import Foundation

@MainActor
final class PlaybackProgressController {
    nonisolated(unsafe) private var timer: Timer?

    func start(onTick: @escaping @MainActor @Sendable () -> Void) {
        stop()
        let progressTimer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                onTick()
            }
        }
        timer = progressTimer
        RunLoop.main.add(progressTimer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}
