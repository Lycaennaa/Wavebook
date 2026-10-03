import Foundation

/// Maintains a bounded viewport over a playback waveform.
public struct PlaybackWaveformViewport: Equatable {
    /// Maximum supported zoom scale.
    public static let maximumZoomScale = 32.0
    /// Total media duration in seconds.
    public private(set) var duration: TimeInterval
    /// Current horizontal zoom scale.
    public private(set) var zoomScale: Double
    /// Start position of the viewport in seconds.
    public private(set) var start: TimeInterval

    /// End position of the viewport in seconds.
    public var end: TimeInterval {
        min(duration, start + visibleDuration)
    }

    /// Visible duration in seconds.
    public var visibleDuration: TimeInterval {
        duration > 0 ? duration / zoomScale : 0
    }

    /// Creates a viewport for a duration.
    public init(duration: TimeInterval = 0) {
        self.duration = 0
        zoomScale = 1
        start = 0
        var viewport = self
        viewport.setDuration(duration)
        self = viewport
    }

    /// Updates the duration while preserving a valid start position.
    public mutating func setDuration(_ duration: TimeInterval) {
        self.duration = Self.safeDuration(duration)
        start = clampedStart(start)
    }

    /// Zooms in around a focus position.
    @discardableResult
    public mutating func zoomIn(centeredAt focus: TimeInterval) -> Bool {
        setZoomScale(min(zoomScale * 2, Self.maximumZoomScale), centeredAt: focus)
    }

    /// Zooms out around a focus position.
    @discardableResult
    public mutating func zoomOut(centeredAt focus: TimeInterval) -> Bool {
        setZoomScale(max(zoomScale / 2, 1), centeredAt: focus)
    }

    /// Sets zoom around a focus position.
    public mutating func setZoomScale(_ scale: Double, centeredAt focus: TimeInterval) -> Bool {
        guard duration > 0 else { return false }
        let newScale = min(max(scale.isFinite ? scale : 1, 1), Self.maximumZoomScale)
        let newVisibleDuration = duration / newScale
        let safeFocus = Self.clamp(focus, to: duration)
        let newStart = clampedStart(safeFocus - newVisibleDuration / 2, visibleDuration: newVisibleDuration)
        let changed = zoomScale != newScale || start != newStart
        zoomScale = newScale
        start = newStart
        return changed
    }

    /// Resets zoom and horizontal position.
    @discardableResult
    public mutating func resetZoom() -> Bool {
        let changed = zoomScale != 1 || start != 0
        zoomScale = 1
        start = 0
        return changed
    }

    /// Pans by a fraction of the visible duration.
    @discardableResult
    public mutating func pan(byFraction fraction: Double) -> Bool {
        guard duration > 0, fraction.isFinite else { return false }
        let newStart = clampedStart(start + visibleDuration * fraction)
        guard newStart != start else { return false }
        start = newStart
        return true
    }

    /// Ensures a playback position is visible.
    @discardableResult
    public mutating func ensureVisible(_ seconds: TimeInterval) -> Bool {
        guard zoomScale > 1 else { return false }
        let safeSeconds = Self.clamp(seconds, to: duration)
        guard safeSeconds < start || safeSeconds > end else { return false }
        let newStart = clampedStart(safeSeconds - visibleDuration / 2)
        guard newStart != start else { return false }
        start = newStart
        return true
    }

    /// Converts a normalized fraction to a media position.
    public func time(at fraction: Double) -> TimeInterval {
        start + visibleDuration * min(max(fraction.isFinite ? fraction : 0, 0), 1)
    }

    /// Converts a media position to a normalized visible fraction.
    public func fraction(for seconds: TimeInterval) -> Double {
        guard visibleDuration > 0 else { return 0 }
        return (Self.clamp(seconds, to: duration) - start) / visibleDuration
    }

    private func clampedStart(_ value: TimeInterval, visibleDuration: TimeInterval? = nil) -> TimeInterval {
        max(min(value, max(duration - (visibleDuration ?? self.visibleDuration), 0)), 0)
    }

    private static func safeDuration(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? value : 0
    }

    private static func clamp(_ value: TimeInterval, to duration: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), duration)
    }
}
