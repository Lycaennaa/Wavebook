import AVFoundation
import Foundation

struct AudioPlaybackPlan: Equatable, Sendable {
    let duration: TimeInterval
    let boundaries: AudioSilenceBoundaries
    let ranges: [AudioPlaybackRange]
    let range: AudioPlaybackRange
    let requestedStartTime: TimeInterval
    let startTime: TimeInterval
    let leadingSkippedDuration: TimeInterval
    let trailingSkippedDuration: TimeInterval
    let leadingSilenceSkippedDuration: TimeInterval
    let trailingSilenceDuration: TimeInterval
}

struct AudioPlaybackPlanner {
    struct Options {
        let precomputedBoundaries: AudioSilenceBoundaries?
        let skipSegments: [AudioSkipSegment]
        let onAnalysisError: ((Error) -> Void)?

        init(
            precomputedBoundaries: AudioSilenceBoundaries? = nil,
            skipSegments: [AudioSkipSegment] = [],
            onAnalysisError: ((Error) -> Void)? = nil
        ) {
            self.precomputedBoundaries = precomputedBoundaries
            self.skipSegments = skipSegments
            self.onAnalysisError = onAnalysisError
        }
    }

    private struct SkipInterval {
        let start: TimeInterval
        let end: TimeInterval
    }

    private struct PlanTiming {
        let sampleRate: Double
        let duration: TimeInterval
        let normalizedStartTime: TimeInterval
        let boundaries: AudioSilenceBoundaries
        let silenceStartTime: TimeInterval
        let silenceEndTime: TimeInterval
    }

    func plan(
        for file: AVAudioFile,
        requestedStartTime: TimeInterval,
        skipSilentSegments: Bool,
        options: Options = .init()
    ) -> AudioPlaybackPlan {
        let timing = makePlanTiming(
            for: file,
            requestedStartTime: requestedStartTime,
            skipSilentSegments: skipSilentSegments,
            options: options
        )
        let intervals = skipIntervals(
            skipSilentSegments: skipSilentSegments,
            silenceStartTime: timing.silenceStartTime,
            silenceEndTime: timing.silenceEndTime,
            duration: timing.duration,
            skipSegments: options.skipSegments
        )
        let mergedIntervals = mergeIntervals(intervals)
        let isInsideTrailingSilence = skipSilentSegments
            && timing.silenceEndTime < timing.duration
            && timing.normalizedStartTime >= timing.silenceEndTime
            && mergedIntervals.contains { $0.start == timing.silenceEndTime && $0.end == timing.duration }
        let startTime = adjustedStartTime(
            timing.normalizedStartTime,
            intervals: mergedIntervals,
            silenceEndTime: timing.silenceEndTime,
            duration: timing.duration,
            isInsideTrailingSilence: isInsideTrailingSilence
        )
        var ranges = playbackRanges(
            from: startTime,
            intervals: mergedIntervals,
            duration: timing.duration,
            sampleRate: timing.sampleRate,
            fileLength: file.length
        )
        appendTrailingSilenceRange(
            to: &ranges,
            isInsideTrailingSilence: isInsideTrailingSilence,
            fileLength: file.length,
            boundaryEndFrame: timing.boundaries.endFrame,
            silenceEndTime: timing.silenceEndTime
        )
        let firstRange = ranges.first ?? AudioPlaybackRange(
            startFrame: file.length,
            endFrame: file.length,
            endTime: timing.duration,
            startTime: timing.duration
        )
        return AudioPlaybackPlan(
            duration: timing.duration,
            boundaries: timing.boundaries,
            ranges: ranges,
            range: firstRange,
            requestedStartTime: timing.normalizedStartTime,
            startTime: startTime,
            leadingSkippedDuration: max(startTime - timing.normalizedStartTime, 0),
            trailingSkippedDuration: max(timing.normalizedStartTime - startTime, 0),
            leadingSilenceSkippedDuration: skipSilentSegments
                ? max(min(startTime, timing.silenceStartTime) -
                    min(timing.normalizedStartTime, timing.silenceStartTime), 0)
                : 0,
            trailingSilenceDuration: skipSilentSegments ? max(timing.duration - timing.silenceEndTime, 0) : 0
        )
    }

    private func makePlanTiming(
        for file: AVAudioFile,
        requestedStartTime: TimeInterval,
        skipSilentSegments: Bool,
        options: Options
    ) -> PlanTiming {
        let sampleRate = file.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        let normalizedStartTime = requestedStartTime.isFinite
            ? min(max(requestedStartTime, 0), duration)
            : 0
        let boundaries = boundaries(
            for: file,
            skipSilentSegments: skipSilentSegments,
            precomputed: options.precomputedBoundaries,
            onAnalysisError: options.onAnalysisError
        )
        let silenceStartTime = sampleRate > 0
            ? min(Double(boundaries.startFrame) / sampleRate, duration)
            : 0
        let silenceEndTime = sampleRate > 0
            ? min(Double(boundaries.endFrame) / sampleRate, duration)
            : 0
        return PlanTiming(
            sampleRate: sampleRate,
            duration: duration,
            normalizedStartTime: normalizedStartTime,
            boundaries: boundaries,
            silenceStartTime: silenceStartTime,
            silenceEndTime: silenceEndTime
        )
    }

    private func appendTrailingSilenceRange(
        to ranges: inout [AudioPlaybackRange],
        isInsideTrailingSilence: Bool,
        fileLength: AVAudioFramePosition,
        boundaryEndFrame: AVAudioFramePosition,
        silenceEndTime: TimeInterval
    ) {
        guard ranges.isEmpty, isInsideTrailingSilence, fileLength > 0 else { return }
        let endFrame = min(max(boundaryEndFrame, 1), fileLength)
        ranges.append(AudioPlaybackRange(
            startFrame: endFrame - 1,
            endFrame: endFrame,
            endTime: silenceEndTime,
            startTime: silenceEndTime
        ))
    }

    private func boundaries(
        for file: AVAudioFile,
        skipSilentSegments: Bool,
        precomputed: AudioSilenceBoundaries?,
        onAnalysisError: ((Error) -> Void)?
    ) -> AudioSilenceBoundaries {
        if let precomputed, skipSilentSegments {
            return precomputed
        }
        guard skipSilentSegments else { return .full(length: file.length) }
        do {
            return try AudioSilenceDetector().boundaries(for: file)
        } catch {
            onAnalysisError?(error)
            return .full(length: file.length)
        }
    }

    private func skipIntervals(
        skipSilentSegments: Bool,
        silenceStartTime: TimeInterval,
        silenceEndTime: TimeInterval,
        duration: TimeInterval,
        skipSegments: [AudioSkipSegment]
    ) -> [SkipInterval] {
        var intervals = [SkipInterval]()
        if skipSilentSegments {
            if silenceStartTime > 0 {
                intervals.append(SkipInterval(start: 0, end: silenceStartTime))
            }
            if silenceEndTime < duration {
                intervals.append(SkipInterval(start: silenceEndTime, end: duration))
            }
        }
        intervals.append(contentsOf: skipSegments.compactMap { segment in
            guard segment.startTime.isFinite, segment.endTime.isFinite else { return nil }
            let start = min(max(segment.startTime, 0), duration)
            let end = min(max(segment.endTime, 0), duration)
            guard end > start else { return nil }
            return SkipInterval(start: start, end: end)
        })
        return intervals.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }
    }

    private func mergeIntervals(_ intervals: [SkipInterval]) -> [SkipInterval] {
        var merged = [SkipInterval]()
        for interval in intervals {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }
            guard interval.start > last.end else {
                merged[merged.count - 1] = SkipInterval(
                    start: last.start,
                    end: max(last.end, interval.end)
                )
                continue
            }
            merged.append(interval)
        }
        return merged
    }

    private func adjustedStartTime(
        _ requestedStartTime: TimeInterval,
        intervals: [SkipInterval],
        silenceEndTime: TimeInterval,
        duration: TimeInterval,
        isInsideTrailingSilence: Bool
    ) -> TimeInterval {
        var startTime = requestedStartTime
        for interval in intervals {
            guard startTime >= interval.start, startTime < interval.end else {
                if interval.start > startTime { break }
                continue
            }
            startTime = isInsideTrailingSilence && interval.start == silenceEndTime
                ? interval.start
                : interval.end
        }
        return min(startTime, duration)
    }

    private func playbackRanges(
        from startTime: TimeInterval,
        intervals: [SkipInterval],
        duration: TimeInterval,
        sampleRate: Double,
        fileLength: AVAudioFramePosition
    ) -> [AudioPlaybackRange] {
        var ranges = [AudioPlaybackRange]()
        var cursor = startTime
        for interval in intervals {
            guard interval.end > cursor else { continue }
            if interval.start > cursor,
               let range = makeRange(
                   start: cursor,
                   end: min(interval.start, duration),
                   sampleRate: sampleRate,
                   fileLength: fileLength
               ) {
                ranges.append(range)
            }
            cursor = max(cursor, interval.end)
            if cursor >= duration { break }
        }
        if cursor < duration,
           let range = makeRange(
               start: cursor,
               end: duration,
               sampleRate: sampleRate,
               fileLength: fileLength
           ) {
            ranges.append(range)
        }
        return ranges
    }

    private func makeRange(
        start: TimeInterval,
        end: TimeInterval,
        sampleRate: Double,
        fileLength: AVAudioFramePosition
    ) -> AudioPlaybackRange? {
        let startFrame = frame(at: start, sampleRate: sampleRate, fileLength: fileLength)
        let endFrame = frame(at: end, sampleRate: sampleRate, fileLength: fileLength)
        guard endFrame > startFrame else { return nil }
        return AudioPlaybackRange(
            startFrame: startFrame,
            endFrame: endFrame,
            endTime: end,
            startTime: start
        )
    }

    private func frame(
        at time: TimeInterval,
        sampleRate: Double,
        fileLength: AVAudioFramePosition
    ) -> AVAudioFramePosition {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return min(max(AVAudioFramePosition(time * sampleRate), 0), fileLength)
    }
}
