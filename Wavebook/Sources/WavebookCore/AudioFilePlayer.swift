import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import OSLog

internal let defaultOutputDeviceAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

/// Main-actor audio-file playback engine.
@MainActor public final class AudioFilePlayer: NSObject {
    nonisolated internal static let logger = Logger(subsystem: "Wavebook", category: "audio-player")
    internal struct PlaybackStateToken: Equatable {
        let playbackID: Int
        let url: URL?
    }

    internal var playbackStateToken: PlaybackStateToken {
        PlaybackStateToken(playbackID: playbackID, url: currentURL)
    }

    internal func isCurrent(_ token: PlaybackStateToken) -> Bool {
        playbackID == token.playbackID && currentURL == token.url
    }
    internal let engine = AVAudioEngine()
    internal let player = AVAudioPlayerNode()
    internal let equalizer = AVAudioUnitEQ(numberOfBands: EqualizerProfile.bandCount)
    internal var appliedEqualizerProfile: EqualizerProfile?
    internal let normalizationGain = AVAudioUnitEQ(numberOfBands: 0)
    internal var playbackChunkLength = AVAudioFramePosition(UInt32.max)
    internal lazy var playbackScheduler: AudioFilePlaybackScheduler = {
        let scheduler = AudioFilePlaybackScheduler(player: player, maximumChunkLength: playbackChunkLength)
        scheduler.onRangeStarted = { [weak self] _, url, range, startTime, playbackID in
            guard let self,
                  self.playbackID == playbackID,
                  self.currentURL == url else { return }
            guard self.currentPlaybackRange != range else { return }
            self.currentPlaybackRange = range
            self.accumulatedElapsed = startTime
        }
        scheduler.onPlaybackFinished = { [weak self] url, range, playbackID in
            guard let self,
                  self.playbackID == playbackID,
                  self.currentURL == url,
                  self.currentPlaybackRange == range,
                  self.engine.isRunning else { return }
            self.finishPlayback(at: range.endTime)
        }
        return scheduler
    }()

    internal enum PlaybackStart {
        case automatic
        case explicit(TimeInterval)
    }

    internal struct AudioFileIdentity: Equatable, Sendable {
        let url: URL
        let frameLength: AVAudioFramePosition
        let fileSize: Int
        let modificationDate: Date
        let sampleRate: Double
        let channelCount: UInt32
    }

    internal struct SilenceAnalysisResult: Sendable {
        let plan: AudioPlaybackPlan
        let sourceIdentity: AudioFileIdentity
    }

    internal var playbackID = 0
    internal var currentNormalizationGainDB = 0.0
    internal var normalizationRampTask: Task<Void, Never>?
    internal var accumulatedElapsed: TimeInterval = 0
    internal var renderBaselineSampleTime: AVAudioFramePosition?
    internal var currentDuration: TimeInterval = 0
    internal var currentPlaybackRange: AudioPlaybackRange?
    internal var currentPlaybackSchedule = AudioPlaybackSchedule.empty
    internal var audibleElapsedAtRenderBaseline: TimeInterval = 0
    internal var audibleElapsedAtPlaybackStart: TimeInterval = 0
    internal var automaticSkipBoundaryIndex = 0
    internal var isDrainingAutomaticSkips = false
    internal var currentTrailingSilenceDuration: TimeInterval = 0
    internal var cachedSilenceAnalysis: (identity: AudioFileIdentity, boundaries: AudioSilenceBoundaries)?
    internal var silenceAnalysisTask: Task<Void, Never>?
    internal var shouldBePlaying = false
    internal var playbackStartedAt: TimeInterval?
    internal var automaticSkipsDisabledForPlayback = false
    nonisolated(unsafe) internal var defaultOutputDeviceListener: AudioObjectPropertyListenerBlock?
    /// Called when playback reaches the end of the current item.
    public var onPlaybackFinished: (() -> Void)?
    /// Called when playback fails.
    public var onPlaybackFailed: ((Error, TimeInterval) -> Void)?
    /// Called when the default output device changes.
    public var onDefaultOutputDeviceChanged: (() -> Void)?
    /// Called when silent segments are detected.
    public var onSilentSegmentsDetected: ((TimeInterval, TimeInterval) -> Void)?
    /// Called when an automatic silent-segment skip occurs.
    public var onSilentSegmentSkipped: ((TimeInterval) -> Void)?
    /// Called when silence analysis completes.
    public var onSilenceAnalysisCompleted: ((Bool, TimeInterval?) -> Void)?
    /// Called when any automatic skip occurs.
    public var onAutomaticSkip: ((TimeInterval, TimeInterval) -> Void)?
    /// URL currently loaded for playback.
    internal(set) public var currentURL: URL?
    /// Last rendered playback position.
    internal(set) public var lastPlaybackPosition: TimeInterval?
    /// User-configured skip segments.
    public var skipSegments: [AudioSkipSegment] = []

    /// Updates skip segments and optionally replans active playback.
    public func setSkipSegments(_ segments: [AudioSkipSegment], applyImmediately: Bool = true) {
        guard self.skipSegments != segments else { return }
        self.skipSegments = segments
        guard applyImmediately else { return }
        replanAfterSkipSegmentsChanged()
    }
    /// Whether automatic silent-segment skipping is enabled.
    public var skipSilentSegments = false {
        didSet {
            guard oldValue != skipSilentSegments, !skipSilentSegments,
                  silenceAnalysisTask != nil else { return }

            let currentPosition = elapsedTime
            playbackID += 1
            silenceAnalysisTask?.cancel()
            silenceAnalysisTask = nil
            guard let currentURL else {
                onSilenceAnalysisCompleted?(false, nil)
                return
            }

            do {
                let file = try AVAudioFile(forReading: currentURL)
                let plan = makePlaybackPlan(
                    for: file,
                    url: currentURL,
                    requestedStartTime: currentPosition,
                    analyzeSilence: false
                )
                if plan.startTime > currentPosition {
                    let callbackState = playbackStateToken
                    onAutomaticSkip?(currentPosition, plan.startTime)
                    guard isCurrent(callbackState) else { return }
                }
                try schedulePlaybackPlan(plan, for: file, url: currentURL)
                onSilenceAnalysisCompleted?(false, nil)
            } catch {
                let position = elapsedTime
                clearPlaybackState()
                onPlaybackFailed?(error, position)
            }
        }
    }
    /// Creates and configures an audio-file player.
    public override init() {
        super.init()
        configureAudioEngine()
    }

    init(playbackChunkLength: AVAudioFramePosition) {
        self.playbackChunkLength = min(max(playbackChunkLength, 1), AVAudioFramePosition(UInt32.max))
        super.init()
        configureAudioEngine()
    }

    deinit {
        normalizationRampTask?.cancel()
        silenceAnalysisTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        if let defaultOutputDeviceListener {
            var address = defaultOutputDeviceAddress
            let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                defaultOutputDeviceListener
            )
            if status != noErr {
                Self.logger.error("Could not remove default-output listener: \(status, privacy: .public)")
            }
        }
    }
}
