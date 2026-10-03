import AppKit
import Foundation
import MediaPlayer
import WavebookCore

extension PlaybackTransportController {
    func play(
        _ track: Track,
        source: ListeningPlaybackSource = ListeningPlaybackSource(kind: .library),
        trackingEndReason: ListeningEventEndReason? = nil,
        onFailure: @escaping () -> Void = {}
    ) -> Bool {
        endSegmentEditorPreview(restoringPendingHistory: false)
        artwork.cancel()
        history.endPlayback(for: track, reason: trackingEndReason)
        let skipSegmentLoad = loadSkipSegments(for: track)
        let skipSegments: [AudioSkipSegment]
        switch skipSegmentLoad {
        case .success(let segments):
            skipSegments = segments
        case .failure:
            skipSegments = []
        }
        audioPlayer.setSkipSegments(skipSegments, applyImmediately: false)

        do {
            let lookup = replayGain.lookup(for: track)
            let gainDB = replayGain.gainDB(for: lookup)
            try audioPlayer.play(URL(fileURLWithPath: track.path), normalizationGainDB: gainDB)
            currentTrack = track
            currentPlaybackSource = source
            if audioPlayer.isSilenceAnalysisPending {
                preview.setPendingHistoryStart(track, source: source)
            } else {
                _ = history.startPlayback(for: track, source: source)
            }
            replayGain.setPresentation(track: track, lookup: lookup, playbackGainDB: gainDB)
            lyrics.load(for: track)
            lyrics.setSkipSegments(skipSegments)
            skipSegmentEditor?.updatePlaybackTrackIfVisible(
                track: track,
                duration: audioPlayer.duration,
                elapsed: readElapsedTime(),
                skipSegmentLoad: skipSegmentLoad
            )
            artwork.start(for: track) { [weak self] in
                self?.emitPresentationChanged()
            }
            updateNowPlaying(state: .playing)
            startProgressTimer()
            updateProgress(notify: false)
            emitPresentationChanged()
            return true
        } catch {
            withPresentationSuppressed {
                onFailure()
                clearPlaybackAfterFailure()
            }
            emitPresentationChanged()
            onEvent?(.error(error, message: "Could not play: \(track.title)", kind: .general))
            return false
        }
    }

    @discardableResult
    func seek(to seconds: TimeInterval, bypassAutomaticSkips: Bool = false) -> Bool {
        endSegmentEditorPreview()
        return seek(to: seconds, bypassAutomaticSkips: bypassAutomaticSkips, recordHistory: true)
    }

    @discardableResult
    func seekFromSegmentEditor(to seconds: TimeInterval) -> Bool {
        preview.beginSegmentEditorPreview()
        return seek(to: seconds, bypassAutomaticSkips: false, recordHistory: false)
    }

    private func startCurrentTrackIfNeeded(
        seconds: TimeInterval,
        bypassAutomaticSkips: Bool,
        recordHistory: Bool
    ) throws -> Bool? {
        guard audioPlayer.currentURL == nil, let currentTrack else { return nil }
        let lookup = replayGain.lookup(for: currentTrack)
        let gainDB = replayGain.gainDB(for: lookup)
        try audioPlayer.play(
            URL(fileURLWithPath: currentTrack.path),
            from: seconds,
            normalizationGainDB: gainDB,
            bypassAutomaticSkips: bypassAutomaticSkips
        )
        if recordHistory {
            _ = history.startPlayback(
                for: currentTrack,
                source: currentPlaybackSource
            )
        }
        replayGain.setPresentation(track: currentTrack, lookup: lookup, playbackGainDB: gainDB)
        updateNowPlaying(state: .playing)
        updateProgress(notify: false)
        startProgressTimer()
        emitPresentationChanged()
        return true
    }

    @discardableResult
    private func seek(to seconds: TimeInterval, bypassAutomaticSkips: Bool, recordHistory: Bool) -> Bool {
        let opensCurrentTrack = audioPlayer.currentURL == nil && currentTrack != nil
        do {
            if let started = try startCurrentTrackIfNeeded(
                seconds: seconds,
                bypassAutomaticSkips: bypassAutomaticSkips,
                recordHistory: recordHistory
            ) {
                return started
            }
            if recordHistory {
                history.prepareForSeek()
            }
            let succeeded = try audioPlayer.seek(to: seconds, bypassAutomaticSkips: bypassAutomaticSkips)
            if recordHistory {
                history.completeSeek(successfully: succeeded)
            }
            guard succeeded else { return false }
            if recordHistory, bypassAutomaticSkips {
                _ = preview.restorePendingHistoryAfterSeek(at: readElapsedTime())
            }
            updateProgress()
            if audioPlayer.isPlaying {
                startProgressTimer()
            }
            return true
        } catch {
            if recordHistory {
                history.completeSeek(successfully: false)
            }
            if opensCurrentTrack || audioPlayer.currentURL != nil {
                withPresentationSuppressed {
                    if audioPlayer.currentURL != nil {
                        history.endPlayback(reason: .unrecoverablePlaybackError)
                    }
                    clearPlaybackAfterFailure()
                }
            }
            emitPresentationChanged()
            onEvent?(.error(error, message: "Could not seek", kind: .general))
            return false
        }
    }

    @discardableResult
    func toggleCurrentPlayback() -> Bool {
        endSegmentEditorPreview()
        if audioPlayer.isPlaying {
            audioPlayer.pause()
            progress.stop()
            history.pause()
            updateNowPlaying(state: .paused)
            emitPresentationChanged()
            return true
        }

        guard audioPlayer.currentURL != nil else { return false }
        do {
            try audioPlayer.resume()
            history.resume()
            startProgressTimer()
            updateNowPlaying(state: .playing)
            emitPresentationChanged()
            return true
        } catch {
            onEvent?(.error(error, message: "Could not resume playback", kind: .general))
            return false
        }
    }
    @discardableResult
    func toggleSegmentEditorPlayback() -> Bool {
        guard currentTrack != nil else { return false }
        preview.beginSegmentEditorPreview()
        guard audioPlayer.currentURL != nil else {
            return seek(to: 0, bypassAutomaticSkips: false, recordHistory: false)
        }
        if audioPlayer.isPlaying {
            audioPlayer.pause()
            progress.stop()
        } else {
            do {
                try audioPlayer.resume()
            } catch {
                onEvent?(.error(error, message: "Could not resume segment preview", kind: .general))
                return false
            }
        }
        updateProgress()
        if audioPlayer.isPlaying {
            startProgressTimer()
        }
        updateNowPlaying(state: audioPlayer.isPlaying ? .playing : .paused)
        emitPresentationChanged()
        return true
    }

    func endSegmentEditorPreview(
        restoringPendingHistory: Bool = true,
        preservePendingHistory: Bool = false
    ) {
        preview.endSegmentEditorPreview(
            restoringPendingHistory: restoringPendingHistory,
            currentTrack: currentTrack,
            hasAudioSource: audioPlayer.currentURL != nil,
            elapsed: readElapsedTime(),
            source: currentPlaybackSource,
            preservePendingHistory: preservePendingHistory
        )
    }
    func showLyrics(owner: NSViewController) {
        lyrics.showLyrics(owner: owner)
    }

    func showDownloadDialog(for track: Track, owner: NSViewController) {
        lyrics.showDownloadDialog(for: track, owner: owner)
    }
    func showSkipSegments(owner: NSViewController) {
        guard let currentTrack else { return }
        showSkipSegments(for: currentTrack, owner: owner)
    }

    func showSkipSegments(for track: Track, owner: NSViewController) {
        let isCurrentTrack = currentTrack?.path == track.path
        guard case .success(let segments) = loadSkipSegments(for: track) else { return }
        if !isCurrentTrack, history.isUntrackedPreviewActive {
            endSegmentEditorPreview()
        }
        let editor = skipSegmentEditor ?? makeSkipSegmentEditor()
        skipSegmentEditor = editor
        editor.show(
            SkipSegmentEditorPresentation(
                owner: owner,
                track: track,
                duration: isCurrentTrack && audioPlayer.duration > 0 ? audioPlayer.duration : track.duration,
                elapsed: isCurrentTrack ? readElapsedTime() : 0,
                isPlaying: isCurrentTrack && audioPlayer.isPlaying,
                volume: audioPlayer.volume,
                segments: segments,
                mode: isCurrentTrack ? .preview : .editing
            )
        )
    }
}
