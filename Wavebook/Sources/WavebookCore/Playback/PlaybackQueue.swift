import Foundation

/// Repeat behavior for the playback queue.
public enum PlaybackRepeatMode: Sendable {
    /// Stop after the final item.
    case off
    /// Wrap to the first item.
    case all
    /// Repeat the current item.
    case one
    /// Whether this mode repeats standalone playback, where the current track is the full sequence.
    public var repeatsStandaloneTrack: Bool {
        switch self {
        case .off: return false
        case .all, .one: return true
        }
    }
}

/// Ordered playback entries and navigation state.
public struct PlaybackQueue: Sendable {
    /// Maximum number of entries retained by the queue.
    public static let maximumEntryCount = 50_000
    /// A track entry with a stable queue identifier.
    public struct Entry: Identifiable, Hashable, Sendable {
        /// Stable entry identifier.
        public let id: UUID
        /// Track represented by the entry.
        public let track: Track
        /// History source associated with this queue entry.
        public let source: ListeningPlaybackSource

        /// Creates a queue entry.
        public init(
            id: UUID = UUID(),
            track: Track,
            source: ListeningPlaybackSource = ListeningPlaybackSource(kind: .library)
        ) {
            self.id = id
            self.track = track
            self.source = source
        }
    }

    /// Outcome of removing queue entries.
    public struct RemovalResult: Sendable {
        /// Entries removed from the queue.
        public let removedEntries: [Entry]
        /// Whether the current entry was removed.
        public let removedCurrentEntry: Bool
    }

    /// Entries in storage order.
    public private(set) var entries: [Entry]
    /// Current storage index.
    public private(set) var currentIndex: Int?
    /// Whether queue order is shuffled.
    public private(set) var isShuffled = false
    /// Current repeat mode.
    public private(set) var repeatMode: PlaybackRepeatMode = .off
    private var currentTrackIsFinished = false
    private var failedPlaybackEntryID: UUID?
    private var playbackOrder: [Int] = []
    private var playbackOrderPosition: Int?

    /// Creates a playback queue.
    public init(items: [Track] = [], currentIndex: Int? = nil) {
        self.entries = items.prefix(Self.maximumEntryCount).map { Entry(track: $0) }
        if let currentIndex, entries.indices.contains(currentIndex) {
            self.currentIndex = currentIndex
        } else {
            self.currentIndex = nil
        }
    }

}

extension PlaybackQueue {
    /// Tracks in storage order.
    public var items: [Track] {
        entries.map(\.track)
    }
    /// Whether the queue contains no entries.
    public var isEmpty: Bool { entries.isEmpty }

    /// Current queue entry.
    public var currentEntry: Entry? {
        guard let currentIndex else { return nil }
        return entries[currentIndex]
    }

    /// Current track.
    public var currentTrack: Track? {
        currentEntry?.track
    }

    /// Entries in playback order.
    public var queuedEntries: [Entry] {
        isShuffled ? playbackOrder.map { entries[$0] } : entries
    }

    /// Tracks in playback order.
    public var queuedItems: [Track] {
        queuedEntries.map(\.track)
    }

    /// Current index in playback order.
    public var currentQueueIndex: Int? {
        guard let currentIndex else { return nil }
        return isShuffled ? playbackOrderPosition : currentIndex
    }

    /// Returns the storage index for an entry.
    public func entryIndex(of entry: Entry) -> Int? {
        entries.firstIndex { $0.id == entry.id }
    }

    /// Returns the playback-order index for an entry.
    public func queueIndex(of entry: Entry) -> Int? {
        guard let index = entryIndex(of: entry) else { return nil }
        return isShuffled ? playbackOrder.firstIndex(of: index) : index
    }

    /// Converts a playback-order index to a storage index.
    public func itemIndex(atQueueIndex index: Int) -> Int? {
        if isShuffled {
            return playbackOrder.indices.contains(index) ? playbackOrder[index] : nil
        }
        return entries.indices.contains(index) ? index : nil
    }

    /// Returns an entry at a storage index.
    public func entry(at index: Int) -> Entry? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    /// Returns an entry at a playback-order index.
    public func entry(atQueueIndex index: Int) -> Entry? {
        guard let itemIndex = itemIndex(atQueueIndex: index) else { return nil }
        return entry(at: itemIndex)
    }

    /// Whether the queue can advance.
    public var canAdvanceToNext: Bool {
        nextIndex != nil
    }

    /// Whether the queue can return to a previous item.
    public var canReturnToPrevious: Bool {
        previousIndex != nil
    }

    /// Storage index of the next item.
    public var nextIndex: Int? {
        nextPlaybackLocation?.index
    }

    private var nextPlaybackLocation: (index: Int, orderPosition: Int?)? {
        if isShuffled {
            guard !playbackOrder.isEmpty else { return nil }
            guard let playbackOrderPosition else { return (playbackOrder[0], 0) }
            let nextPosition = playbackOrderPosition + 1
            if playbackOrder.indices.contains(nextPosition) {
                return (playbackOrder[nextPosition], nextPosition)
            }
            return repeatsQueue ? (playbackOrder[0], 0) : nil
        }

        let index = currentIndex.map { $0 + 1 } ?? 0
        if entries.indices.contains(index) {
            return (index, nil)
        }
        return repeatsQueue ? entries.indices.first.map { ($0, nil) } : nil
    }

    /// Storage index of the previous item.
    public var previousIndex: Int? {
        previousPlaybackLocation?.index
    }

    private var previousPlaybackLocation: (index: Int, orderPosition: Int?)? {
        guard let currentIndex else { return nil }

        if isShuffled {
            guard let playbackOrderPosition else { return nil }
            let previousPosition = playbackOrderPosition - 1
            if playbackOrder.indices.contains(previousPosition) {
                return (playbackOrder[previousPosition], previousPosition)
            }
            guard repeatsQueue, let lastPosition = playbackOrder.indices.last else { return nil }
            return (playbackOrder[lastPosition], lastPosition)
        }

        let index = currentIndex - 1
        if entries.indices.contains(index) {
            return (index, nil)
        }
        return repeatsQueue ? entries.indices.last.map { ($0, nil) } : nil
    }

    /// Storage index selected for playback.
    public var playbackIndex: Int? {
        if let failedIndex = failedPlaybackEntryIndex {
            if failedIndex != currentIndex {
                return failedIndex
            }
            guard let currentIndex,
                  let nextIndex = nextIndex,
                  nextIndex != currentIndex else { return nil }
            return nextIndex
        }
        if currentTrackIsFinished, repeatMode == .one, currentIndex != nil {
            return currentIndex
        }
        return currentTrackIsFinished ? nextIndex : currentIndex ?? nextIndex
    }

    /// Whether playback has reached the queue end.
    public var isAtEnd: Bool {
        if failedPlaybackEntryIndex != nil {
            return playbackIndex == nil
        }
        return currentTrackIsFinished && nextIndex == nil
    }

    private var failedPlaybackEntryIndex: Int? {
        guard let failedPlaybackEntryID else { return nil }
        return entries.firstIndex { $0.id == failedPlaybackEntryID }
    }

    /// Returns a track at a storage index.
    public func track(at index: Int) -> Track? {
        entry(at: index)?.track
    }

    /// Appends one track.
    public mutating func append(
        _ track: Track,
        source: ListeningPlaybackSource = ListeningPlaybackSource(kind: .library)
    ) {
        guard entries.count < Self.maximumEntryCount else { return }
        let index = entries.endIndex
        entries.append(Entry(track: track, source: source))
        insertIntoShuffledOrder([index])
    }

    /// Appends tracks in order.
    public mutating func append(
        contentsOf tracks: [Track],
        source: ListeningPlaybackSource = ListeningPlaybackSource(kind: .library)
    ) {
        let acceptedCount = min(tracks.count, Self.maximumEntryCount - entries.count)
        guard acceptedCount > 0 else { return }
        let acceptedTracks = tracks.prefix(acceptedCount)
        let newIndices = Array(entries.endIndex..<(entries.endIndex + acceptedCount))
        entries.append(contentsOf: acceptedTracks.map { Entry(track: $0, source: source) })
        insertIntoShuffledOrder(newIndices)
    }

    /// Inserts tracks immediately after the current item.
    public mutating func insertNext(
        _ tracks: [Track],
        source: ListeningPlaybackSource = ListeningPlaybackSource(kind: .library)
    ) {
        let acceptedCount = min(tracks.count, Self.maximumEntryCount - entries.count)
        guard acceptedCount > 0 else { return }
        let acceptedTracks = tracks.prefix(acceptedCount)
        let insertionIndex = currentIndex.map { $0 + 1 } ?? 0
        entries.insert(contentsOf: acceptedTracks.map { Entry(track: $0, source: source) }, at: insertionIndex)
        guard isShuffled else { return }
        playbackOrder = playbackOrder.map { $0 >= insertionIndex ? $0 + acceptedCount : $0 }
        let orderInsertionIndex = playbackOrderPosition.map { $0 + 1 } ?? 0
        playbackOrder.insert(contentsOf: insertionIndex..<(insertionIndex + acceptedCount), at: orderInsertionIndex)
    }

    /// Replaces all tracks and resets playback state.
    public mutating func replace(
        with tracks: [Track],
        source: ListeningPlaybackSource = ListeningPlaybackSource(kind: .library)
    ) {
        entries = tracks.prefix(Self.maximumEntryCount).map { Entry(track: $0, source: source) }
        currentIndex = nil
        currentTrackIsFinished = false
        failedPlaybackEntryID = nil
        rebuildPlaybackOrder()
    }
    /// Updates favorite state without changing queue entry identities, source, or order.
    public mutating func updateFavoriteState(trackID: Int64, isFavorite: Bool) {
        for index in entries.indices where entries[index].track.id == trackID {
            var track = entries[index].track
            track.isFavorite = isFavorite
            entries[index] = Entry(
                id: entries[index].id,
                track: track,
                source: entries[index].source
            )
        }
    }

    /// Enables or disables shuffled playback order.
    public mutating func setShuffleEnabled(_ enabled: Bool) {
        guard isShuffled != enabled else { return }
        isShuffled = enabled
        rebuildPlaybackOrder()
    }

    /// Sets queue repeat behavior.
    public mutating func setRepeatMode(_ mode: PlaybackRepeatMode) {
        repeatMode = mode
    }

}

extension PlaybackQueue {
    /// Starts playback at a storage index.
    @discardableResult
    public mutating func play(at index: Int) -> Track? {
        guard entries.indices.contains(index) else { return nil }
        let orderPosition = isShuffled ? playbackOrder.firstIndex(of: index) : nil
        return play(at: index, playbackOrderPosition: orderPosition)
    }
    private mutating func play(at index: Int, playbackOrderPosition: Int?) -> Track? {
        guard let entry = entry(at: index) else { return nil }
        currentIndex = index
        currentTrackIsFinished = false
        failedPlaybackEntryID = nil
        if isShuffled {
            self.playbackOrderPosition = playbackOrderPosition
        }
        return entry.track
    }

    /// Starts playback for a queue entry.
    @discardableResult
    public mutating func play(_ entry: Entry) -> Track? {
        guard let index = entryIndex(of: entry) else { return nil }
        return play(at: index)
    }

    /// Marks the current track as finished.
    public mutating func markCurrentTrackFinished() {
        currentTrackIsFinished = true
    }

    /// Marks the current track as failed.
    public mutating func markCurrentTrackPlaybackFailed() {
        guard let currentEntry else { return }
        currentTrackIsFinished = true
        failedPlaybackEntryID = currentEntry.id
    }

    /// Marks a queue entry as failed.
    public mutating func markPlaybackFailed(for entry: Entry) {
        guard let index = entryIndex(of: entry) else { return }
        failedPlaybackEntryID = entries[index].id
        if index == currentIndex {
            currentTrackIsFinished = true
        }
    }

    /// Advances to the next track.
    @discardableResult
    public mutating func next() -> Track? {
        guard let location = nextPlaybackLocation else { return nil }
        return play(at: location.index, playbackOrderPosition: location.orderPosition)
    }

    /// Returns to the previous track.
    @discardableResult
    public mutating func previous() -> Track? {
        guard let location = previousPlaybackLocation else { return nil }
        return play(at: location.index, playbackOrderPosition: location.orderPosition)
    }

    /// Removes a track at a storage index.
    @discardableResult
    public mutating func remove(at index: Int) -> Track? {
        guard entries.indices.contains(index) else { return nil }
        let removedEntry = entries.remove(at: index)
        if failedPlaybackEntryID == removedEntry.id {
            failedPlaybackEntryID = nil
        }
        let removed = removedEntry.track
        if isShuffled, let removedOrderPosition = playbackOrder.firstIndex(of: index) {
            playbackOrder.remove(at: removedOrderPosition)
            playbackOrder = playbackOrder.map { $0 > index ? $0 - 1 : $0 }
            if let playbackOrderPosition {
                if removedOrderPosition < playbackOrderPosition {
                    self.playbackOrderPosition = playbackOrderPosition - 1
                } else if removedOrderPosition == playbackOrderPosition {
                    self.playbackOrderPosition = removedOrderPosition - 1
                }
            }
        }

        if let currentIndex {
            if currentIndex == index {
                self.currentIndex = nil
                currentTrackIsFinished = false
            } else if index < currentIndex {
                self.currentIndex = currentIndex - 1
            }
        }

        return removed
    }

    /// Removes queue entries by stable identifier.
    @discardableResult
    public mutating func removeEntries(withIDs ids: [UUID]) -> RemovalResult {
        guard !ids.isEmpty else {
            return RemovalResult(removedEntries: [], removedCurrentEntry: false)
        }

        let currentEntryID = currentEntry?.id
        var removedEntries: [Entry] = []
        var processedIDs = Set<UUID>()
        for id in ids where processedIDs.insert(id).inserted {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { continue }
            let entry = entries[index]
            _ = remove(at: index)
            removedEntries.append(entry)
        }

        let removedCurrentEntry = currentEntryID.map { currentID in
            removedEntries.contains { $0.id == currentID }
        } ?? false
        return RemovalResult(removedEntries: removedEntries, removedCurrentEntry: removedCurrentEntry)
    }

    /// Removes a queue entry.
    @discardableResult
    public mutating func remove(_ entry: Entry) -> Entry? {
        guard let index = entryIndex(of: entry) else { return nil }
        let removed = entries[index]
        _ = remove(at: index)
        return removed
    }

    /// Moves an entry in storage order.
    @discardableResult
    public mutating func move(from source: Int, to destination: Int) -> Bool {
        guard entries.indices.contains(source), entries.indices.contains(destination) else { return false }
        guard source != destination else { return true }

        let moved = entries.remove(at: source)
        entries.insert(moved, at: destination)

        if isShuffled {
            playbackOrder = playbackOrder.map { index in
                if index == source { return destination }
                if source < destination, index > source, index <= destination { return index - 1 }
                if source > destination, index >= destination, index < source { return index + 1 }
                return index
            }
        }

        guard let currentIndex else { return true }
        if currentIndex == source {
            self.currentIndex = destination
        } else if source < currentIndex, destination >= currentIndex {
            self.currentIndex = currentIndex - 1
        } else if source > currentIndex, destination <= currentIndex {
            self.currentIndex = currentIndex + 1
        }
        return true
    }

    /// Moves an entry in playback order.
    @discardableResult
    public mutating func moveQueuedItem(from source: Int, to destination: Int) -> Bool {
        guard isShuffled else { return move(from: source, to: destination) }
        guard playbackOrder.indices.contains(source), playbackOrder.indices.contains(destination) else { return false }
        guard source != destination else { return true }

        let moved = playbackOrder.remove(at: source)
        playbackOrder.insert(moved, at: destination)
        playbackOrderPosition = currentIndex.flatMap { playbackOrder.firstIndex(of: $0) }
        return true
    }

    /// Moves an entry in playback order by identity.
    @discardableResult
    public mutating func moveQueuedItem(_ entry: Entry, to destination: Int) -> Bool {
        guard let source = queueIndex(of: entry) else { return false }
        return moveQueuedItem(from: source, to: destination)
    }

    /// Removes all entries and resets queue state.
    public mutating func clear() {
        entries.removeAll()
        currentIndex = nil
        currentTrackIsFinished = false
        failedPlaybackEntryID = nil
        playbackOrder.removeAll()
        playbackOrderPosition = nil
    }

    private var repeatsQueue: Bool {
        repeatMode == .all
    }

    private mutating func rebuildPlaybackOrder() {
        guard isShuffled else {
            playbackOrder.removeAll()
            playbackOrderPosition = nil
            return
        }

        playbackOrder = Array(entries.indices)
        if let currentIndex {
            playbackOrder.removeAll { $0 == currentIndex }
            playbackOrder.shuffle()
            playbackOrder.insert(currentIndex, at: 0)
            playbackOrderPosition = 0
        } else {
            playbackOrder.shuffle()
            playbackOrderPosition = nil
        }
    }

    private mutating func insertIntoShuffledOrder(_ indices: [Int]) {
        guard isShuffled else { return }
        let firstUpcomingPosition = playbackOrderPosition.map { $0 + 1 } ?? 0
        for index in indices {
            let insertionPosition = Int.random(in: firstUpcomingPosition...playbackOrder.endIndex)
            playbackOrder.insert(index, at: insertionPosition)
        }
    }
}
