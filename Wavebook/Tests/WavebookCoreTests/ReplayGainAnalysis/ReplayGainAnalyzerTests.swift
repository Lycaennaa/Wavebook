import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
@testable import WavebookCore
import XCTest

extension ReplayGainAnalyzerTests {
    func testMeasuresStereoPCMIntegratedLoudnessAndSamplePeak() throws {
        let url = try makeSineWAV(amplitude: 0.5)

        let measurement = try ReplayGainAnalyzer().measure(url: url)

        XCTAssertEqual(measurement.samplePeak, 0.5, accuracy: 0.0001)
        XCTAssertEqual(measurement.integratedLUFS, -6.05, accuracy: 0.1)
        XCTAssertEqual(measurement.values.gain?.source, .measured)
    }

    func testLongSupportedTrackStillMeasuresAcrossChunks() throws {
        let url = try makeSineWAV(duration: 12, amplitude: 0.5)

        let measurement = try ReplayGainAnalyzer(chunkFrameCapacity: 1_024).measure(url: url)

        XCTAssertEqual(measurement.samplePeak, 0.5, accuracy: 0.0001)
        XCTAssertEqual(measurement.integratedLUFS, -6.05, accuracy: 0.1)
    }
    func testAlbumMeasurementUsesCombinedLoudnessAndMaximumPeak() throws {
        let loud = try makeSineWAV(amplitude: 0.5)
        let quiet = try makeSineWAV(amplitude: 0.25)
        let analyzer = ReplayGainAnalyzer()
        let loudMeasurement = try analyzer.measure(url: loud)
        let quietMeasurement = try analyzer.measure(url: quiet)

        let albumMeasurement = try analyzer.measureAlbum(urls: [loud, quiet])

        XCTAssertEqual(albumMeasurement.samplePeak, 0.5, accuracy: 0.0001)
        XCTAssertLessThan(albumMeasurement.integratedLUFS, loudMeasurement.integratedLUFS)
        XCTAssertGreaterThan(albumMeasurement.integratedLUFS, quietMeasurement.integratedLUFS)
    }

    func testAsyncAlbumMeasurementMatchesSequentialLoudness() async throws {
        let loud = try makeSineWAV(amplitude: 0.5)
        let quiet = try makeSineWAV(amplitude: 0.25)
        let analyzer = ReplayGainAnalyzer()
        let expected = try analyzer.measureAlbum(urls: [loud, quiet]).values

        let values = try await analyzer.albumValues(
            tagURLs: [],
            measurementURLs: [loud, quiet]
        )

        XCTAssertEqual(values, expected)
    }

    func testAlbumValuesUsesCachedTrackMeasurement() async throws {
        let loud = try makeSineWAV(amplitude: 0.5)
        let quiet = try makeSineWAV(amplitude: 0.25)
        let analyzer = ReplayGainAnalyzer()
        let cached = try analyzer.decodedMeasurement(url: loud)
        let fingerprint = ReplayGainFileFingerprint.current(path: loud.path)
        let expected = try ReplayGainAlbumDecoder.makeMeasurement(
            snapshots: [cached.snapshot],
            samplePeak: cached.samplePeak
        ).values

        try Data(contentsOf: quiet).write(to: loud)

        let values = try await analyzer.albumValues(
            tagURLs: [],
            measurementURLs: [loud],
            cachedMeasurements: [
                ReplayGainAnalyzer.ReplayGainCachedMeasurement(
                    path: loud.path,
                    fingerprint: fingerprint,
                    measurement: cached
                )
            ]
        )

        XCTAssertEqual(values, expected)
    }

    func testMeasurementCacheRejectsChangedSourceAndClears() async throws {
        let loud = try makeSineWAV(amplitude: 0.5)
        let analyzer = ReplayGainAnalyzer()
        let measurement = try analyzer.decodedMeasurement(url: loud)
        let originalFingerprint = ReplayGainFileFingerprint.current(path: loud.path)
        let cache = ReplayGainMeasurementCache()
        await cache.store(measurement, for: loud.path, fingerprint: originalFingerprint)

        let cached = await cache.values(
            for: [loud.path],
            fingerprints: [loud.path: originalFingerprint]
        )
        XCTAssertEqual(cached.count, 1)

        try Data([1, 2, 3]).write(to: loud)
        let changedFingerprint = ReplayGainFileFingerprint.current(path: loud.path)
        let changedValues = await cache.values(
            for: [loud.path],
            fingerprints: [loud.path: changedFingerprint]
        )
        XCTAssertTrue(changedValues.isEmpty)
        await cache.removeAll()
        let clearedValues = await cache.values(
            for: [loud.path],
            fingerprints: [loud.path: changedFingerprint]
        )
        XCTAssertTrue(clearedValues.isEmpty)
    }

    func testAlbumDecoderRespectsConfiguredConcurrency() async throws {
        let measurement = try makeDecoderMeasurement()
        let probe = AnalysisConcurrencyProbe()
        let urls = (0..<5).map { URL(fileURLWithPath: "/virtual/\($0)") }
        let decoder = ReplayGainAlbumDecoder(
            concurrency: 2,
            cancellationCheck: {},
            decode: { _ in
                probe.enter()
                defer { probe.leave() }
                try await Task.sleep(for: .milliseconds(20))
                return measurement
            }
        )

        let result = try await decoder.measure(urls: urls)

        XCTAssertEqual(probe.callCount, urls.count)
        XCTAssertEqual(probe.maximumActiveCount, 2)
        XCTAssertEqual(result.samplePeak, 0.5)
    }

    func testAlbumTagsFromUnavailableMemberRemainAuthoritative() async throws {
        let tagged = try fixtureURL(fileExtension: "flac")

        let values = try await ReplayGainAnalyzer().albumValues(
            tagURLs: [tagged],
            measurementURLs: []
        )

        XCTAssertEqual(values.gain, ReplayGainGain(decibels: -6.5, source: .replayGain))
        XCTAssertEqual(values.samplePeak, 1.012345)
    }

    func testCompressedFixturesDecode() throws {
        let analyzer = ReplayGainAnalyzer()

        for fileExtension in ["mp3", "flac", "opus"] {
                 XCTAssertGreaterThan(
                     try analyzer.samplePeak(url: fixtureURL(fileExtension: fileExtension)),
                     0,
                     fileExtension
                 )
        }
    }

}
