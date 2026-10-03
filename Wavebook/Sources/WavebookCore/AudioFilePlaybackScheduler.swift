import AVFoundation
import Foundation

struct AudioPlaybackRange: Hashable, Sendable {
    let startFrame: AVAudioFramePosition
    let endFrame: AVAudioFramePosition
    let startTime: TimeInterval
    let endTime: TimeInterval

    init(
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition,
        endTime: TimeInterval,
        startTime: TimeInterval = 0
    ) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.startTime = startTime
        self.endTime = endTime
    }

    func advanced(by frameCount: AVAudioFramePosition) -> Self {
        let availableFrameCount = max(endFrame - startFrame, 0)
        let advancedFrameCount = min(max(frameCount, 0), availableFrameCount)
        return Self(
            startFrame: startFrame + advancedFrameCount,
            endFrame: endFrame,
            endTime: endTime,
            startTime: startTime
        )
    }
}

@MainActor
final class AudioFilePlaybackScheduler {
    private static let maximumPreparedTransitionCount = 256

    private struct RangeCompletion {
        let url: URL
        let playbackID: Int
        let generation: Int
        let index: Int
        let range: AudioPlaybackRange
    }

    private let player: AVAudioPlayerNode
    private let maximumChunkLength: AVAudioFramePosition
    private var scheduleGeneration = 0
    private var scheduledFile: AVAudioFile?
    private var rangeIndex = 0
    private var scheduledBuffers: [AVAudioPCMBuffer] = []
    private var preparedSchedule = AudioPlaybackSchedule.empty

    var onRangeStarted: ((AVAudioFile, URL, AudioPlaybackRange, TimeInterval, Int) -> Void)?
    var onRangeSkipped: ((TimeInterval, TimeInterval, Int) -> Void)?
    var onPlaybackFinished: ((URL, AudioPlaybackRange, Int) -> Void)?

    init(
        player: AVAudioPlayerNode,
        maximumChunkLength: AVAudioFramePosition = AVAudioFramePosition(UInt32.max)
    ) {
        self.player = player
        self.maximumChunkLength = min(max(maximumChunkLength, 1), AVAudioFramePosition(UInt32.max))
    }

    func invalidate() {
        scheduleGeneration += 1
        scheduledFile = nil
        scheduledBuffers.removeAll(keepingCapacity: false)
        preparedSchedule = .empty
        rangeIndex = 0
    }

    @discardableResult
    func schedule(
        file: AVAudioFile,
        url: URL,
        range: AudioPlaybackRange,
        playbackID id: Int
    ) -> AudioPlaybackSchedule {
        schedule(file: file, url: url, ranges: [range], playbackID: id)
    }

    @discardableResult
    func schedule(
        file: AVAudioFile,
        url: URL,
        ranges: [AudioPlaybackRange],
        playbackID id: Int
    ) -> AudioPlaybackSchedule {
        scheduleGeneration += 1
        let generation = scheduleGeneration
        scheduledFile = file
        let validRanges = ranges.filter { $0.endFrame > $0.startFrame }
        let prepared = makePreparedSchedule(file: file, url: url, ranges: validRanges)
        scheduledBuffers = Array(prepared.transitionBuffers.values)
        self.preparedSchedule = prepared.schedule
        rangeIndex = 0
        guard let firstRange = prepared.schedule.firstRange else { return prepared.schedule }

        onRangeStarted?(file, url, firstRange, prepared.schedule.startTime(forRangeAt: 0), id)
        let context = RangeSchedulingContext(
            file: file,
            url: url,
            playbackID: id,
            generation: generation,
            transitionBuffers: prepared.transitionBuffers
        )
        for (index, scheduledRange) in prepared.schedule.scheduledRanges.enumerated() {
            schedule(scheduledRange, at: index, context: context)
        }
        return prepared.schedule
    }

    private struct PreparedSchedule {
        let schedule: AudioPlaybackSchedule
        let transitionBuffers: [AudioPlaybackRange: AVAudioPCMBuffer]
    }

    private struct RangeSchedulingContext {
        let file: AVAudioFile
        let url: URL
        let playbackID: Int
        let generation: Int
        let transitionBuffers: [AudioPlaybackRange: AVAudioPCMBuffer]
    }

    private func makePreparedSchedule(
        file: AVAudioFile,
        url: URL,
        ranges: [AudioPlaybackRange]
    ) -> PreparedSchedule {
        let candidateSchedule = AudioPlaybackSchedule(
            ranges: ranges,
            sampleRate: file.processingFormat.sampleRate
        )
        let outputFormat = player.outputFormat(forBus: 0)
        let transitionCount = candidateSchedule.scheduledRanges.reduce(into: 0) { count, scheduledRange in
            if scheduledRange.trailingTransitionFrameCount > 0 { count += 1 }
        }
        if transitionCount > Self.maximumPreparedTransitionCount {
            AudioFilePlayer.logger.debug(
                "Skip crossfade disabled for \(transitionCount) boundaries, privacy: .private"
            )
        }
        let candidateBuffers: [AudioPlaybackRange: AVAudioPCMBuffer]?
        if transitionCount > 0, transitionCount <= Self.maximumPreparedTransitionCount {
            do {
                candidateBuffers = try AudioPlaybackTransitionBuilder.makeBuffers(
                    for: candidateSchedule,
                    url: url,
                    format: file.processingFormat,
                    outputFormat: outputFormat
                )
            } catch {
                AudioFilePlayer.logger.debug(
                    "Skip crossfade preparation failed: \(String(describing: error), privacy: .private)"
                )
                candidateBuffers = nil
            }
        } else {
            candidateBuffers = nil
        }

        let preparedSchedule: AudioPlaybackSchedule
        let transitionBuffers: [AudioPlaybackRange: AVAudioPCMBuffer]
        if let candidateBuffers,
           candidateSchedule.scheduledRanges.allSatisfy({ scheduledRange in
               scheduledRange.trailingTransitionFrameCount == 0
                   || candidateBuffers[scheduledRange.source] != nil
           }) {
            var transitionDurations = [AudioPlaybackRange: TimeInterval]()
            if outputFormat.sampleRate > 0 {
                for (range, buffer) in candidateBuffers {
                    transitionDurations[range] = Double(buffer.frameLength) / outputFormat.sampleRate
                }
            }
            preparedSchedule = candidateSchedule.withTransitionOutputDurations(transitionDurations)
            transitionBuffers = candidateBuffers
        } else {
            preparedSchedule = AudioPlaybackSchedule(
                ranges: ranges,
                sampleRate: file.processingFormat.sampleRate,
                crossfadeDuration: 0
            )
            transitionBuffers = [:]
        }
        return PreparedSchedule(schedule: preparedSchedule, transitionBuffers: transitionBuffers)
    }

    private struct RangeCompletionContext: Sendable {
        let url: URL
        let playbackID: Int
        let generation: Int
        let index: Int
        let range: AudioPlaybackRange
    }

    private func schedule(
        _ scheduledRange: AudioPlaybackSchedule.ScheduledRange,
        at index: Int,
        context: RangeSchedulingContext
    ) {
        let file = context.file
        let url = context.url
        let playbackID = context.playbackID
        let generation = context.generation
        let transitionBuffers = context.transitionBuffers
        let range = scheduledRange.source
        let leadingFrameCount = scheduledRange.leadingTransitionFrameCount
        let trailingFrameCount = scheduledRange.trailingTransitionFrameCount
        let startFrame = range.startFrame + leadingFrameCount
        let endFrame = range.endFrame - trailingFrameCount
        let completion = RangeCompletionContext(
            url: url,
            playbackID: playbackID,
            generation: generation,
            index: index,
            range: range
        )
        var frame = startFrame
        while frame < endFrame {
            let chunkLength = min(endFrame - frame, maximumChunkLength)
            let frameCount = AVAudioFrameCount(chunkLength)
            let isFinalChunk = frame + chunkLength == endFrame
            scheduleChunk(
                file: file,
                startingFrame: frame,
                frameCount: frameCount,
                completion: isFinalChunk && trailingFrameCount == 0 ? completion : nil
            )
            frame += chunkLength
        }

        guard trailingFrameCount > 0,
              let transitionBuffer = transitionBuffers[scheduledRange.source] else { return }
        scheduleTransitionBuffer(transitionBuffer, completion: completion)
    }

    private func scheduleChunk(
        file: AVAudioFile,
        startingFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        completion: RangeCompletionContext?
    ) {
        guard let completion else {
            player.scheduleSegment(
                file,
                startingFrame: startingFrame,
                frameCount: frameCount,
                at: nil,
                completionCallbackType: .dataConsumed,
                completionHandler: nil
            )
            return
        }
        let completionHandler: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.scheduleGeneration == completion.generation else { return }
                self.finishRange(RangeCompletion(
                    url: completion.url,
                    playbackID: completion.playbackID,
                    generation: completion.generation,
                    index: completion.index,
                    range: completion.range
                ))
            }
        }
        player.scheduleSegment(
            file,
            startingFrame: startingFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: completionHandler
        )
    }

    private func scheduleTransitionBuffer(
        _ buffer: AVAudioPCMBuffer,
        completion: RangeCompletionContext
    ) {
        let completionHandler: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.scheduleGeneration == completion.generation else { return }
                self.finishRange(RangeCompletion(
                    url: completion.url,
                    playbackID: completion.playbackID,
                    generation: completion.generation,
                    index: completion.index,
                    range: completion.range
                ))
            }
        }
        player.scheduleBuffer(
            buffer,
            at: nil,
            completionCallbackType: .dataPlayedBack,
            completionHandler: completionHandler
        )
    }

    private func finishRange(_ completion: RangeCompletion) {
        guard scheduleGeneration == completion.generation,
              rangeIndex == completion.index,
              let file = scheduledFile else { return }
        if completion.index + 1 < preparedSchedule.rangeCount {
            let nextRange = preparedSchedule.range(at: completion.index + 1)
            if nextRange.startTime > completion.range.endTime {
                onRangeSkipped?(completion.range.endTime, nextRange.startTime, completion.playbackID)
            }
            rangeIndex = completion.index + 1
            onRangeStarted?(
                file,
                completion.url,
                nextRange,
                preparedSchedule.startTime(forRangeAt: completion.index + 1),
                completion.playbackID
            )
        } else {
            onPlaybackFinished?(completion.url, completion.range, completion.playbackID)
        }
    }
}
