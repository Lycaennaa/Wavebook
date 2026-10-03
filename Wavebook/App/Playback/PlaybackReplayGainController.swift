import Foundation
import WavebookCore

@MainActor
final class PlaybackReplayGainController {
    struct Lookup {
        let data: ReplayGainNormalizationData?
        let errorReason: String?
    }

    private let databaseProvider: () -> LibraryDatabase?
    private let shouldLoadData: () -> Bool

    private(set) var mode = ReplayGainMode.defaultValue
    private(set) var presentation = ReplayGainPresentation.empty(mode: .defaultValue)

    var onModeChanged: (() -> Void)?
    var onEvent: ((PlaybackSessionEvent) -> Void)?

    init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        shouldLoadData: @escaping () -> Bool
    ) {
        self.databaseProvider = databaseProvider
        self.shouldLoadData = shouldLoadData
    }

    func lookup(for track: Track) -> Lookup {
        guard mode != .off || shouldLoadData() else {
            return Lookup(data: nil, errorReason: nil)
        }
        guard let database = databaseProvider() else {
            return Lookup(data: nil, errorReason: "ReplayGain database is unavailable")
        }

        do {
            let data: ReplayGainNormalizationData?
            if let trackID = track.id {
                data = try database.replayGainData(trackID: trackID)
            } else {
                data = try database.replayGainData(path: track.path)
            }
            onEvent?(.clearOperationalErrors(.database))
            return Lookup(data: data, errorReason: nil)
        } catch {
            onEvent?(.error(error, message: "Could not load ReplayGain data for: \(track.title)", kind: .database))
            return Lookup(data: nil, errorReason: error.localizedDescription)
        }
    }

    func gainDB(for lookup: Lookup) -> Double {
        ReplayGain.appliedGainDB(mode: mode, track: lookup.data?.track, album: lookup.data?.album)
    }

    func setPresentation(track: Track?, lookup: Lookup?, playbackGainDB: Double?) {
        guard let track, let lookup else {
            presentation = .empty(mode: mode)
            return
        }
        presentation = ReplayGainPresentation(
            track: track,
            data: lookup.data,
            mode: mode,
            playbackGainDB: playbackGainDB,
            cacheError: lookup.errorReason
        )
    }

    func refresh(currentTrack: Track?, audioPlayer: AudioFilePlayer) {
        guard let currentTrack else {
            setPresentation(track: nil, lookup: nil, playbackGainDB: nil)
            return
        }
        let lookup = lookup(for: currentTrack)
        let isCurrentPlayback = audioPlayer.currentURL?.path == currentTrack.path
        let gainDB = gainDB(for: lookup)
        if isCurrentPlayback {
            audioPlayer.setNormalizationGainDB(
                gainDB,
                rampDuration: audioPlayer.isPlaying ? 0.1 : 0
            )
        }
        setPresentation(
            track: currentTrack,
            lookup: lookup,
            playbackGainDB: isCurrentPlayback ? gainDB : nil
        )
    }

    func applySavedMode() {
        do {
            mode = try databaseProvider()?.replayGainMode() ?? .defaultValue
            onEvent?(.clearOperationalErrors(.database))
        } catch {
            mode = .defaultValue
            onEvent?(.error(error, message: "Could not load saved ReplayGain mode", kind: .database))
        }
        presentation = .empty(mode: mode)
        onModeChanged?()
    }
    func applySavedMode(_ savedMode: ReplayGainMode) {
        mode = savedMode
        presentation = .empty(mode: mode)
        onModeChanged?()
    }

    @discardableResult
    func cycleMode() -> Bool {
        guard let database = databaseProvider() else { return false }
        let nextMode = mode.next
        do {
            try database.saveReplayGainMode(nextMode)
            onEvent?(.clearOperationalErrors(.database))
        } catch {
            onEvent?(.error(error, message: "Could not save ReplayGain mode", kind: .database))
            return false
        }
        mode = nextMode
        presentation = ReplayGainPresentation(
            track: presentation.track,
            data: presentation.data,
            mode: mode,
            playbackGainDB: presentation.playbackGainDB,
            cacheError: presentation.cacheError
        )
        onModeChanged?()
        return true
    }

    func clearPresentation() {
        presentation = .empty(mode: mode)
    }
}
