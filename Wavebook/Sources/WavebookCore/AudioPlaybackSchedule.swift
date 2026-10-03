import AVFoundation
import Foundation

struct AudioPlaybackSchedule: Equatable, Sendable {
    struct ScheduledRange: Hashable, Sendable {
        let source: AudioPlaybackRange
        let leadingTransitionFrameCount: AVAudioFramePosition
        let trailingTransitionFrameCount: AVAudioFramePosition
        let trailingTransitionOutputDuration: TimeInterval
    }
    static let defaultCrossfadeDuration: TimeInterval = 0.04
    static let empty = AudioPlaybackSchedule(ranges: [], sampleRate: 0, crossfadeDuration: 0)

    struct OutputSegment: Equatable, Sendable {
        let sourceStartTime: TimeInterval
        let sourceEndTime: TimeInterval
        let outputDuration: TimeInterval
    }

    let scheduledRanges: [ScheduledRange]
    let sampleRate: Double
    let outputSegments: [OutputSegment]
    let outputDuration: TimeInterval

    var rangeCount: Int {
        scheduledRanges.count
    }

    var firstRange: AudioPlaybackRange? {
        scheduledRanges.first?.source
    }

    func range(at index: Int) -> AudioPlaybackRange {
        scheduledRanges[index].source
    }

    init(
        ranges: [AudioPlaybackRange],
        sampleRate: Double,
        crossfadeDuration: TimeInterval = AudioPlaybackSchedule.defaultCrossfadeDuration
    ) {
        let validRanges = ranges.filter { $0.endFrame > $0.startFrame }
        let transitionFrameCounts = Self.makeTransitionFrameCounts(
            for: validRanges,
            sampleRate: sampleRate,
            crossfadeDuration: crossfadeDuration
        )
        let scheduledRanges = validRanges.enumerated().map { index, range in
            let trailingFrameCount = transitionFrameCounts[index]
            return ScheduledRange(
                source: range,
                leadingTransitionFrameCount: index > 0 ? transitionFrameCounts[index - 1] : 0,
                trailingTransitionFrameCount: trailingFrameCount,
                trailingTransitionOutputDuration: Double(trailingFrameCount) / sampleRate
            )
        }
        self.init(scheduledRanges: scheduledRanges, sampleRate: sampleRate)
    }
    private init(scheduledRanges: [ScheduledRange], sampleRate: Double) {
        self.scheduledRanges = scheduledRanges
        self.sampleRate = sampleRate
        self.outputSegments = Self.makeOutputSegments(
            for: scheduledRanges,
            sampleRate: sampleRate
        )
        self.outputDuration = outputSegments.reduce(0) { $0 + $1.outputDuration }
    }

    func withTransitionOutputDurations(
        _ durations: [AudioPlaybackRange: TimeInterval]
    ) -> Self {
        guard !durations.isEmpty else { return self }
        let updatedRanges = scheduledRanges.map { scheduledRange in
            ScheduledRange(
                source: scheduledRange.source,
                leadingTransitionFrameCount: scheduledRange.leadingTransitionFrameCount,
                trailingTransitionFrameCount: scheduledRange.trailingTransitionFrameCount,
                trailingTransitionOutputDuration: durations[scheduledRange.source]
                    ?? scheduledRange.trailingTransitionOutputDuration
            )
        }
        return Self(scheduledRanges: updatedRanges, sampleRate: sampleRate)
    }

    func startTime(forRangeAt index: Int) -> TimeInterval {
        guard scheduledRanges.indices.contains(index) else { return 0 }
        let scheduledRange = scheduledRanges[index]
        guard index > 0, sampleRate > 0 else { return scheduledRange.source.startTime }
        return scheduledRange.source.startTime
            + Double(scheduledRange.leadingTransitionFrameCount) / sampleRate
    }

    func sourcePosition(forAudibleElapsed audibleElapsed: TimeInterval) -> TimeInterval {
        guard let firstSegment = outputSegments.first else {
            return firstRange?.startTime ?? 0
        }
        var remaining = max(audibleElapsed, 0)
        for segment in outputSegments {
            guard segment.outputDuration > 0 else { continue }
            if remaining <= segment.outputDuration {
                let progress = min(max(remaining / segment.outputDuration, 0), 1)
                return segment.sourceStartTime
                    + (segment.sourceEndTime - segment.sourceStartTime) * progress
            }
            remaining -= segment.outputDuration
        }
        return outputSegments.last?.sourceEndTime ?? firstSegment.sourceStartTime
    }

    func audibleElapsed(forSourcePosition sourcePosition: TimeInterval) -> TimeInterval {
        guard let firstSegment = outputSegments.first else { return 0 }
        let position = max(sourcePosition, firstSegment.sourceStartTime)
        var elapsed = 0.0
        for segment in outputSegments {
            let sourceDuration = segment.sourceEndTime - segment.sourceStartTime
            guard sourceDuration > 0, segment.outputDuration > 0 else { continue }
            if position <= segment.sourceStartTime {
                return elapsed
            }
            if position < segment.sourceEndTime {
                let progress = (position - segment.sourceStartTime) / sourceDuration
                return elapsed + segment.outputDuration * min(max(progress, 0), 1)
            }
            elapsed += segment.outputDuration
        }
        return elapsed
    }

    private static func makeTransitionFrameCounts(
        for ranges: [AudioPlaybackRange],
        sampleRate: Double,
        crossfadeDuration: TimeInterval
    ) -> [AVAudioFramePosition] {
        var counts = Array(repeating: AVAudioFramePosition(0), count: ranges.count)
        guard ranges.count > 1,
              sampleRate.isFinite,
              sampleRate > 0,
              crossfadeDuration.isFinite,
              crossfadeDuration > 0 else { return counts }

        let requestedFrameCount = AVAudioFramePosition(crossfadeDuration * sampleRate)
        guard requestedFrameCount >= 2 else { return counts }
        for index in 0..<(ranges.count - 1) {
            let current = ranges[index]
            let next = ranges[index + 1]
            guard next.startFrame > current.endFrame else { continue }
            let currentFrameCount = current.endFrame - current.startFrame
            let nextFrameCount = next.endFrame - next.startFrame
            let maximumFrameCount = min(currentFrameCount / 2, nextFrameCount / 2)
            guard maximumFrameCount >= 2 else { continue }
            counts[index] = min(requestedFrameCount, maximumFrameCount)
        }
        return counts
    }

    private static func makeOutputSegments(
        for scheduledRanges: [ScheduledRange],
        sampleRate: Double
    ) -> [OutputSegment] {
        guard sampleRate.isFinite, sampleRate > 0 else { return [] }
        var segments = [OutputSegment]()
        for index in scheduledRanges.indices {
            let scheduledRange = scheduledRanges[index]
            let range = scheduledRange.source
            let leadingFrameCount = scheduledRange.leadingTransitionFrameCount
            let trailingFrameCount = scheduledRange.trailingTransitionFrameCount
            let normalStartFrame = range.startFrame + leadingFrameCount
            let normalEndFrame = range.endFrame - trailingFrameCount
            if normalEndFrame > normalStartFrame {
                let normalStartTime = range.startTime
                    + Double(leadingFrameCount) / sampleRate
                let normalEndTime = range.endTime
                    - Double(trailingFrameCount) / sampleRate
                segments.append(OutputSegment(
                    sourceStartTime: normalStartTime,
                    sourceEndTime: normalEndTime,
                    outputDuration: Double(normalEndFrame - normalStartFrame) / sampleRate
                ))
            }

            guard trailingFrameCount > 0, index + 1 < scheduledRanges.count else { continue }
            let sourceTransitionDuration = Double(trailingFrameCount) / sampleRate
            segments.append(OutputSegment(
                sourceStartTime: range.endTime - sourceTransitionDuration,
                sourceEndTime: scheduledRanges[index + 1].source.startTime + sourceTransitionDuration,
                outputDuration: scheduledRange.trailingTransitionOutputDuration
            ))
        }
        return segments
    }
}
