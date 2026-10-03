import AppKit
import WavebookCore

struct ReplayGainPresentation {
    let track: Track?
    let data: ReplayGainNormalizationData?
    let mode: ReplayGainMode
    let playbackGainDB: Double?
    let cacheError: String?

    static func empty(mode: ReplayGainMode) -> ReplayGainPresentation {
        ReplayGainPresentation(track: nil, data: nil, mode: mode, playbackGainDB: nil, cacheError: nil)
    }
}

struct PlaybackTransportPresentation {
    let track: Track?
    let artwork: NSImage?
    let duration: TimeInterval
    let elapsed: TimeInterval
    let isPlaying: Bool
    let lyricsEnabled: Bool
    let lyricsPreview: LyricsPlaybackPreview
    let replayGain: ReplayGainPresentation
}

struct PlaybackQueuePresentation {
    let entries: [PlaybackQueue.Entry]
    let revision: UInt64
    let currentIndex: Int?
    let isShuffled: Bool
    let repeatMode: PlaybackRepeatMode
}

struct PlaybackPresentationState {
    let queue: PlaybackQueuePresentation
    let transport: PlaybackTransportPresentation
    let shouldScrollQueueToCurrent: Bool
}

enum PlaybackSessionEvent {
    case error(Error, message: String, kind: OperationalErrorKind)
    case clearOperationalErrors(OperationalErrorKind)
    case persistenceError(String)
    case persistenceWarningChanged(String?)
    case initialPersistenceWarning(String)
    case outputDeviceChanged
    case presentOperationalMessage(String, kind: OperationalErrorKind)
    case libraryContentChanged
    case replayGainActionError(String)
}
