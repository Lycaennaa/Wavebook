import AVFoundation
@testable import WavebookCore
import XCTest

@MainActor final class AudioFilePlayerTests: XCTestCase {
    func testMissingFileDoesNotBecomeCurrentTrack() {
        let player = makeSilentPlayer()

        XCTAssertThrowsError(try player.play(URL(fileURLWithPath: "/definitely/missing.wav")))
        XCTAssertNil(player.currentURL)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(player.elapsedTime, 0)
    }

    func testEqualizerProfileUpdatesAndConfigurationRestore() {
        let player = makeSilentPlayer()
        let gains = (0..<EqualizerProfile.bandCount).map { Double($0) / 10 - 1.5 }
        let profile = EqualizerProfile(preamp: 3, isBypassed: false, bandGains: gains)

        player.apply(equalizerProfile: profile)
        XCTAssertEqual(player.equalizer.globalGain, 3, accuracy: 0.0001)
        XCTAssertEqual(player.equalizer.bands[5].gain, Float(gains[5]), accuracy: 0.0001)
        XCTAssertEqual(player.equalizer.bands[5].frequency, Float(EqualizerProfile.frequencies[5]), accuracy: 0.0001)
        XCTAssertEqual(player.equalizer.bands[5].filterType, .parametric)
        XCTAssertFalse(player.equalizer.bands[5].bypass)

        player.restoreEqualizerProfileAfterEngineConfiguration()
        XCTAssertEqual(player.equalizer.globalGain, 3, accuracy: 0.0001)
        XCTAssertEqual(player.equalizer.bands[5].gain, Float(gains[5]), accuracy: 0.0001)

        let bypassed = EqualizerProfile(preamp: 3, isBypassed: true, bandGains: gains)
        player.apply(equalizerProfile: bypassed)
        XCTAssertEqual(player.equalizer.globalGain, 0)
        XCTAssertTrue(player.equalizer.bands[5].bypass)
    }

    func testPlayAThenFailBDoesNotRetainAudioState() throws {
        let trackA = try makeWAV()
        let player = makeSilentPlayer()
        try player.play(trackA, normalizationGainDB: -6)

        XCTAssertEqual(player.currentURL, trackA)
        XCTAssertThrowsError(try player.play(URL(fileURLWithPath: "/definitely/missing.wav")))

        XCTAssertNil(player.currentURL)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.normalizationGainDB, 0)
        XCTAssertEqual(player.effectiveNormalizationGainDB, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(player.elapsedTime, 0)
    }
    func testFailedEngineRecoveryClearsPriorTrack() throws {
        let trackA = try makeWAV()
        let player = makeSilentPlayer()
        var failureWasReported = false
        player.onPlaybackFailed = { _, _ in
            failureWasReported = true
        }
        try player.play(trackA, normalizationGainDB: -6)
        try FileManager.default.removeItem(at: trackA)

        player.handleEngineConfigurationChanged()

        XCTAssertTrue(failureWasReported)
        XCTAssertNil(player.currentURL)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(player.elapsedTime, 0)
        XCTAssertEqual(player.normalizationGainDB, 0)
        XCTAssertEqual(player.effectiveNormalizationGainDB, 0)
    }

    func testVolumeClampsToPlayerRange() {
        let player = makeSilentPlayer()

        player.volume = -1
        XCTAssertEqual(player.volume, 0)

        player.volume = 2
        XCTAssertEqual(player.volume, 1)
    }

    func testNormalizationGainClampsIndependentlyFromUserVolume() {
        let player = makeSilentPlayer()
        player.volume = 0.4

        player.setNormalizationGainDB(20)
        XCTAssertEqual(player.normalizationGainDB, 12)
        XCTAssertEqual(player.volume, 0.4)

        player.setNormalizationGainDB(-200)
        XCTAssertEqual(player.normalizationGainDB, -96)
        XCTAssertEqual(player.volume, 0.4)

        player.setNormalizationGainDB(.nan)
        XCTAssertEqual(player.normalizationGainDB, 0)
    }

    func testSeekWithoutCurrentTrackFails() {
        let player = makeSilentPlayer()

        XCTAssertFalse(try player.seek(to: 10))
        XCTAssertEqual(player.elapsedTime, 0)
    }

    func testNormalizationRampChangesEffectiveGainAndCannotAffectNextPlayback() async throws {
        let player = makeSilentPlayer()
        try player.play(makeWAV(), normalizationGainDB: -12)

        player.setNormalizationGainDB(6, rampDuration: 0.1)
        XCTAssertEqual(player.effectiveNormalizationGainDB, -12, accuracy: 0.01)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(player.effectiveNormalizationGainDB, -12)
        XCTAssertLessThan(player.effectiveNormalizationGainDB, 6)

        try player.play(makeWAV(), normalizationGainDB: -3)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(player.normalizationGainDB, -3)
        XCTAssertEqual(player.effectiveNormalizationGainDB, -3, accuracy: 0.01)
        player.stop()
    }

    func testEngineConfigurationChangeContinuesPlayback() throws {
        let url = try makeWAV()
        let player = makeSilentPlayer()
        try player.play(url, normalizationGainDB: -6)
        Thread.sleep(forTimeInterval: 0.05)
        let elapsedBeforeChange = player.elapsedTime

        player.handleEngineConfigurationChanged()

        XCTAssertEqual(player.currentURL, url)
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThan(player.duration, 0)
        XCTAssertGreaterThanOrEqual(player.elapsedTime, elapsedBeforeChange)
        XCTAssertEqual(player.normalizationGainDB, -6)
        player.stop()
        XCTAssertEqual(player.normalizationGainDB, 0)
    }

    func testDefaultOutputDeviceChangeNotifiesWithoutCurrentTrack() {
        let player = makeSilentPlayer()
        var notificationCount = 0
        player.onDefaultOutputDeviceChanged = {
            notificationCount += 1
        }

        player.handleDefaultOutputDeviceChanged()

        XCTAssertEqual(notificationCount, 1)
    }

    func testNaturalCompletionStillFinishesPlayback() async throws {
        let url = try makeWAV(sampleCount: 800)
        let player = makeSilentPlayer()
        let finished = expectation(description: "Playback finished")
        player.onPlaybackFinished = {
            finished.fulfill()
        }

        try player.play(url, normalizationGainDB: -6)
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertNil(player.currentURL)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.normalizationGainDB, 0)
        XCTAssertEqual(player.effectiveNormalizationGainDB, 0)
    }

    func testPauseStopsAudioEngineAndResumeRestartsPlayback() throws {
        let url = try makeTestWAV(for: self, samples: Array(repeating: Int16(10_000), count: 16_000))
        let player = makeSilentPlayer()
        try player.play(url)
        XCTAssertTrue(player.engine.isRunning)

        player.pause()
        XCTAssertFalse(player.engine.isRunning)
        let pausedPosition = player.elapsedTime

        try player.resume()
        XCTAssertTrue(player.engine.isRunning)
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThanOrEqual(player.elapsedTime, pausedPosition)
        player.stop()
    }

    func testPauseCancelsPendingSilenceAnalysisAndResumeRestartsIt() async throws {
        let url = try makeTestWAV(for: self, samples: Array(repeating: Int16(0), count: 80_000))
        let player = makeSilentPlayer()
        player.skipSilentSegments = true
        let analyzed = expectation(description: "Silence analysis completed after resume")
        player.onSilenceAnalysisCompleted = { _, _ in analyzed.fulfill() }

        try player.play(url)
        XCTAssertTrue(player.isSilenceAnalysisPending)
        player.pause()
        XCTAssertFalse(player.isSilenceAnalysisPending)

        try player.resume()
        XCTAssertTrue(player.isSilenceAnalysisPending)
        await fulfillment(of: [analyzed], timeout: 4)
        player.stop()
    }

    func testPausedSilenceAnalysisCanResumeAfterDisablingSkipping() async throws {
        let url = try makeTestWAV(for: self, samples: Array(repeating: Int16(0), count: 80_000))
        let player = makeSilentPlayer()
        player.skipSilentSegments = true
        let analysisCompleted = expectation(description: "Pending history resolved after fallback plan")
        player.onSilenceAnalysisCompleted = { didAnalyze, _ in
            XCTAssertFalse(didAnalyze)
            analysisCompleted.fulfill()
        }
        try player.play(url)
        XCTAssertTrue(player.isSilenceAnalysisPending)

        player.pause()
        XCTAssertFalse(player.isSilenceAnalysisPending)
        player.skipSilentSegments = false

        try player.resume()
        await fulfillment(of: [analysisCompleted], timeout: 4)

        XCTAssertEqual(player.currentURL, url)
        XCTAssertTrue(player.engine.isRunning)
        XCTAssertTrue(player.isPlaying)
        player.stop()
    }

    func testPlaybackRangeAdvancesByChunk() {
        let range = AudioPlaybackRange(startFrame: 0, endFrame: 20_000, endTime: 2.5)

        XCTAssertEqual(range.advanced(by: 16_384).startFrame, 16_384)
        XCTAssertEqual(range.advanced(by: 20_000).startFrame, 20_000)
    }

    func testSilentSkippingUsesDetectedBoundaries() async throws {
        let leadingSilence = 3_200
        let signal = 20_000
        let trailingSilence = 16_000
        let samples = Array(repeating: Int16(0), count: leadingSilence)
            + Array(repeating: Int16(10_000), count: signal)
            + Array(repeating: Int16(0), count: trailingSilence)
        let url = try makeTestWAV(for: self, samples: samples)
        let player = makeSilentPlayer(playbackChunkLength: 4_096)
        player.skipSilentSegments = true
        let finished = expectation(description: "Trimmed playback finished")
        let skippedTrailing = expectation(description: "Trailing silence skipped")
        player.onPlaybackFinished = {
            finished.fulfill()
        }
        player.onSilentSegmentSkipped = { duration in
            XCTAssertEqual(duration, 2, accuracy: 0.01)
            skippedTrailing.fulfill()
        }
        let detected = expectation(description: "Silence boundaries detected")
        player.onSilentSegmentsDetected = { leadingDuration, trailingDuration in
            XCTAssertEqual(leadingDuration, 0.4, accuracy: 0.01)
            XCTAssertEqual(trailingDuration, 2, accuracy: 0.01)
            detected.fulfill()
        }
        let applied = expectation(description: "Silence boundaries applied")
        player.onSilenceAnalysisCompleted = { successfully, position in
            XCTAssertTrue(successfully)
            guard let position else {
                XCTFail("Successful silence analysis must report a position")
                applied.fulfill()
                return
            }
            XCTAssertEqual(position, 0.4, accuracy: 0.01)
            applied.fulfill()
        }

        try player.play(url)

        XCTAssertEqual(player.duration, Double(samples.count) / 8_000, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(player.elapsedTime, 0)
        await fulfillment(of: [finished, skippedTrailing, detected, applied], timeout: 4)
        XCTAssertNil(player.currentURL)
        XCTAssertEqual(player.elapsedTime, player.duration, accuracy: 0.05)
    }
    func testSilentSkippingClampsExplicitSeekToAudibleEnd() async throws {
        let leadingSilence = 3_200
        let signal = 20_000
        let trailingSilence = 16_000
        let samples = Array(repeating: Int16(0), count: leadingSilence)
            + Array(repeating: Int16(10_000), count: signal)
            + Array(repeating: Int16(0), count: trailingSilence)
        let url = try makeTestWAV(for: self, samples: samples)
        let player = makeSilentPlayer(playbackChunkLength: 4_096)
        player.skipSilentSegments = true

        let prepared = expectation(description: "Silence boundaries applied")
        player.onSilenceAnalysisCompleted = { successfully, _ in
            XCTAssertTrue(successfully)
            prepared.fulfill()
        }
        try player.play(url)
        await fulfillment(of: [prepared], timeout: 1)

        let detected = expectation(description: "Seek skip adjustment detected")
        player.onSilentSegmentsDetected = { leadingDuration, trailingDuration in
            XCTAssertEqual(leadingDuration, 0, accuracy: 0.01)
            XCTAssertEqual(trailingDuration, 2, accuracy: 0.01)
            detected.fulfill()
        }
        XCTAssertTrue(try player.seek(to: 4))
        await fulfillment(of: [detected], timeout: 1)
        player.pause()

        XCTAssertEqual(player.elapsedTime, 2.9, accuracy: 0.05)
        player.stop()
    }

    func testUserSkipSegmentsChainAndReportSourceGaps() async throws {
        let url = try makeTestWAV(for: self, samples: Array(repeating: Int16(10_000), count: 16_000))
        let player = makeSilentPlayer(playbackChunkLength: 1_024)
        player.skipSegments = [
            AudioSkipSegment(startTime: 0.4, endTime: 0.8),
            AudioSkipSegment(startTime: 1.2, endTime: 1.6)
        ]
        let finished = expectation(description: "User skip playback finished")
        let skipped = expectation(description: "User skip gaps reported")
        var gaps = [(TimeInterval, TimeInterval)]()
         player.onAutomaticSkip = { from, end in
             gaps.append((from, end))
            if gaps.count == 2 {
                skipped.fulfill()
            }
        }
        player.onPlaybackFinished = {
            finished.fulfill()
        }

        try player.play(url)
        await fulfillment(of: [finished, skipped], timeout: 4)

        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps[0].0, 0.4, accuracy: 0.05)
        XCTAssertEqual(gaps[0].1, 0.8, accuracy: 0.05)
        XCTAssertEqual(gaps[1].0, 1.2, accuracy: 0.05)
        XCTAssertEqual(gaps[1].1, 1.6, accuracy: 0.05)
        XCTAssertEqual(player.elapsedTime, player.duration, accuracy: 0.05)
    }
    func testLyricSeekBypassesSegmentsForOnePlaybackOnly() async throws {
        let url = try makeTestWAV(for: self, samples: Array(repeating: Int16(10_000), count: 16_000))
        let player = makeSilentPlayer(playbackChunkLength: 1_024)
        player.skipSegments = [AudioSkipSegment(startTime: 0.4, endTime: 0.8)]

        try player.play(url)
        XCTAssertTrue(try player.seek(to: 0.5, bypassAutomaticSkips: true))
        player.pause()
        XCTAssertEqual(player.elapsedTime, 0.5, accuracy: 0.05)
        player.stop()

        let skipped = expectation(description: "Automatic skip restored on next playback")
         player.onAutomaticSkip = { from, end in
             XCTAssertEqual(from, 0.4, accuracy: 0.05)
             XCTAssertEqual(end, 0.8, accuracy: 0.05)
            skipped.fulfill()
        }
        try player.play(url)
        await fulfillment(of: [skipped], timeout: 2)
        player.stop()
    }

    private func makeSilentPlayer(
        playbackChunkLength: AVAudioFramePosition? = nil
    ) -> AudioFilePlayer {
        let player: AudioFilePlayer
        if let playbackChunkLength {
            player = AudioFilePlayer(playbackChunkLength: playbackChunkLength)
        } else {
            player = AudioFilePlayer()
        }
        player.volume = 0
        return player
    }

    private func makeWAV(sampleCount: UInt32 = 16_000) throws -> URL {
        try makeTestWAV(for: self, samples: Array(repeating: 0, count: Int(sampleCount)))
    }
}
