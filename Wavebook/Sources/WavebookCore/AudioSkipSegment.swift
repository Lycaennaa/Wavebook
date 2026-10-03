import Foundation

/// A bounded playback segment skipped during playback.
public struct AudioSkipSegment: Identifiable, Hashable, Sendable {
    /// Stable segment identifier.
    public let id: UUID
    /// Segment start position in seconds.
    public let startTime: TimeInterval
    /// Segment end position in seconds.
    public let endTime: TimeInterval

    /// Creates a playback skip segment.
    public init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
    }

    /// Duration of the segment in seconds.
    public var duration: TimeInterval {
        max(endTime - startTime, 0)
    }
}
