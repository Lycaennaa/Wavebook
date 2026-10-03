import Foundation
import WavebookCore

@MainActor
final class LyricsFileAvailabilityCache {
    private struct Entry {
        let value: Bool
        let checkedAt: Date
    }

    private struct PendingRequest {
        let audioURL: URL
        let database: LibraryDatabase?
    }

    private let loader = LRCLyricsLoader()
    private var entries = [String: Entry]()
    private var pending = [String: PendingRequest]()
    private var tasks = [String: Task<Void, Never>]()
    private var observers = [String: [(Bool) -> Void]]()
    private var database: LibraryDatabase?
    private let entryLifetime: TimeInterval = 30
    private let maximumEntries = 512
    private let maximumPending = 512
    private let maximumConcurrentTasks = 4

    func value(for path: String) -> Bool? {
        guard let entry = entries[path] else { return nil }
        guard Date().timeIntervalSince(entry.checkedAt) < entryLifetime else {
            entries.removeValue(forKey: path)
            return nil
        }
        return entry.value
    }

    func prefetch(_ tracks: [Track], database: LibraryDatabase?) {
        if database != nil {
            self.database = database
        }
        let resolvedDatabase = database ?? self.database
        for track in tracks {
            let path = track.path
            guard tasks[path] == nil, pending[path] == nil, pending.count < maximumPending else { continue }
            entries.removeValue(forKey: path)
            pending[path] = PendingRequest(
                audioURL: URL(fileURLWithPath: path),
                database: resolvedDatabase
            )
        }
        startPendingTasks()
    }

    func prefetch(_ tracks: [Track]) {
        prefetch(tracks, database: database)
    }

    func observe(path: String, completion: @escaping (Bool) -> Void) {
        if let value = value(for: path) {
            completion(value)
            return
        }
        observers[path, default: []].append(completion)
    }

    private func startPendingTasks() {
        while tasks.count < maximumConcurrentTasks,
              let path = pending.keys.first,
              let request = pending.removeValue(forKey: path) {
            let loader = loader
            tasks[path] = Task { @MainActor [weak self] in
                do {
                    let available = try await loader.lyricFileURL(
                        for: request.audioURL,
                        database: request.database
                    ) != nil
                    guard !Task.isCancelled else {
                        self?.finish(path: path, value: nil)
                        return
                    }
                    self?.finish(path: path, value: available)
                } catch {
                    guard !Task.isCancelled else {
                        self?.finish(path: path, value: nil)
                        return
                    }
                    self?.finish(path: path, value: false)
                }
            }
        }
    }

    private func finish(path: String, value: Bool?) {
        tasks[path] = nil
        if let value {
            entries[path] = Entry(value: value, checkedAt: Date())
            pruneEntries()
            let callbacks = observers.removeValue(forKey: path) ?? []
            callbacks.forEach { $0(value) }
        }
        startPendingTasks()
    }

    private func pruneEntries() {
        while entries.count > maximumEntries {
            guard let oldestPath = entries.min(by: {
                $0.value.checkedAt < $1.value.checkedAt
            })?.key else { return }
            entries.removeValue(forKey: oldestPath)
        }
    }

    deinit {
        tasks.values.forEach { $0.cancel() }
    }
}
