import Foundation

/// Guards asynchronous playback requests against stale completions.
public struct PlaybackRequestGeneration: Equatable, Sendable {
    private var value: UInt64 = 0

    /// Creates an empty request-generation gate.
    public init() {}

    /// Starts a new request and returns its generation token.
    @discardableResult
    public mutating func begin() -> UInt64 {
        value &+= 1
        return value
    }

    /// Invalidates the current request.
    public mutating func cancel() {
        value &+= 1
    }

    /// Whether a completion belongs to the current request.
    public func accepts(_ generation: UInt64) -> Bool {
        generation == value
    }
}
