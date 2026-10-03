@testable import WavebookCore
import XCTest

final class ReplayGainTests: XCTestCase {
    func testParsesReplayGainTagsCaseInsensitivelyWithWhitespaceAndUnits() {
        let tags = ReplayGain.parse(tags: [
            "replaygain_track_gain": "  -7.25 dB  ",
            "ReplayGain_Track_Peak": " 1.125 ",
            "REPLAYGAIN_ALBUM_GAIN": "-6.5DB",
            "replaygain_album_peak": "0.75"
        ])

        XCTAssertEqual(tags.track?.gain, ReplayGainGain(decibels: -7.25, source: .replayGain))
        XCTAssertEqual(tags.track?.samplePeak, 1.125)
        XCTAssertEqual(tags.album?.gain, ReplayGainGain(decibels: -6.5, source: .replayGain))
        XCTAssertEqual(tags.album?.samplePeak, 0.75)
    }

    func testRejectsMalformedNonfiniteUnsupportedAndOutOfRangeValues() {
        let tags = ReplayGain.parse(tags: [
            "REPLAYGAIN_TRACK_GAIN": "3 LUFS",
            "REPLAYGAIN_TRACK_PEAK": "nan",
            "R128_TRACK_GAIN": "32768",
            "REPLAYGAIN_ALBUM_GAIN": "infinity",
            "REPLAYGAIN_ALBUM_PEAK": "0",
            "R128_ALBUM_GAIN": "1.5"
        ])

        XCTAssertNil(tags.track)
        XCTAssertNil(tags.album)
    }

    func testReplayGainWinsOverR128WithinEachScope() {
        let tags = ReplayGain.parse(tags: [
            "REPLAYGAIN_TRACK_GAIN": "-4 dB",
            "R128_TRACK_GAIN": "-256",
            "REPLAYGAIN_ALBUM_GAIN": "-3 dB",
            "R128_ALBUM_GAIN": "0"
        ])

        XCTAssertEqual(tags.track?.gain, ReplayGainGain(decibels: -4, source: .replayGain))
        XCTAssertEqual(tags.album?.gain, ReplayGainGain(decibels: -3, source: .replayGain))
    }

    func testR128Q78ConversionIncludesTargetOffset() {
        XCTAssertEqual(
            ReplayGain.parse(tags: ["R128_TRACK_GAIN": "0"]).track?.gain,
            ReplayGainGain(decibels: 5, source: .r128)
        )
        XCTAssertEqual(
            ReplayGain.parse(tags: ["R128_TRACK_GAIN": "-256"]).track?.gain,
            ReplayGainGain(decibels: 4, source: .r128)
        )
        XCTAssertEqual(
            ReplayGain.parse(tags: ["R128_TRACK_GAIN": "-1280"]).track?.gain,
            ReplayGainGain(decibels: 0, source: .r128)
        )
    }

    func testScopesRemainIndependentAndMissingPeakIsNotReady() {
        let tags = ReplayGain.parse(tags: [
            "REPLAYGAIN_TRACK_GAIN": "-2 dB",
            "REPLAYGAIN_ALBUM_PEAK": "0.9"
        ])

        XCTAssertEqual(tags.track?.gain?.decibels, -2)
        XCTAssertNil(tags.track?.samplePeak)
        XCTAssertEqual(tags.track?.isReady, false)
        XCTAssertNil(tags.album?.gain)
        XCTAssertEqual(tags.album?.samplePeak, 0.9)
        XCTAssertEqual(tags.album?.isReady, false)
    }

    func testInvalidConstructedValuesAreNotReady() {
        XCTAssertFalse(
            ReplayGainScopeValues(
                gain: ReplayGainGain(decibels: .nan, source: .measured),
                samplePeak: 1
            ).isReady
        )
        XCTAssertFalse(
            ReplayGainScopeValues(
                gain: ReplayGainGain(decibels: 0, source: .measured),
                samplePeak: 0
            ).isReady
        )
    }

    func testMeasuredValuesFillOnlyMissingTagFields() {
        let tagged = ReplayGainScopeValues(
            gain: ReplayGainGain(decibels: -4, source: .replayGain)
        )
        let measured = ReplayGainScopeValues(
            gain: ReplayGainGain(decibels: -8, source: .measured),
            samplePeak: 0.8
        )

        XCTAssertEqual(
            tagged.fillingMissing(from: measured),
            ReplayGainScopeValues(
                gain: ReplayGainGain(decibels: -4, source: .replayGain),
                samplePeak: 0.8
            )
        )
    }

    func testMeasuredGainUsesMinus18LUFSTarget() {
        XCTAssertEqual(ReplayGain.measuredGainDB(integratedLUFS: -23), 5)
        XCTAssertEqual(ReplayGain.measuredGainDB(integratedLUFS: -18), 0)
        XCTAssertNil(ReplayGain.measuredGainDB(integratedLUFS: .nan))
    }

     func testAppliedGainUsesBoostCapAndSamplePeakHeadroom() throws {
        let boostCapped = ReplayGainScopeValues(
            gain: ReplayGainGain(decibels: 20, source: .measured),
            samplePeak: 0.1
        )
        let peakCapped = ReplayGainScopeValues(
            gain: ReplayGainGain(decibels: 10, source: .measured),
            samplePeak: 0.5
        )
        let overFullScale = ReplayGainScopeValues(
            gain: ReplayGainGain(decibels: 3, source: .measured),
            samplePeak: 2
        )

         XCTAssertEqual(
             try XCTUnwrap(ReplayGain.appliedGainDB(for: boostCapped)),
             12,
             accuracy: 0.000_001
         )
         XCTAssertEqual(
             try XCTUnwrap(ReplayGain.appliedGainDB(for: peakCapped)),
             20 * log10(2),
             accuracy: 0.000_001
         )
         XCTAssertEqual(
             try XCTUnwrap(ReplayGain.appliedGainDB(for: overFullScale)),
             -20 * log10(2),
             accuracy: 0.000_001
         )
        XCTAssertNil(ReplayGain.appliedGainDB(for: ReplayGainScopeValues(gain: boostCapped.gain)))
    }

    func testAlbumPeakUsesMaximumValidMemberPeak() {
        XCTAssertEqual(ReplayGain.albumSamplePeak([0.5, .nan, -1, 1.25, 0]), 1.25)
        XCTAssertNil(ReplayGain.albumSamplePeak([Double.nan, 0, -1]))
    }

    func testAlbumModeUsesAlbumClampThenTrackAndUnityFallbacks() {
        let track = ReplayGainScopeValues(
            gain: ReplayGainGain(decibels: 6, source: .measured),
            samplePeak: 0.5
        )
        let album = ReplayGainScopeValues(
            gain: ReplayGainGain(decibels: 4, source: .measured),
            samplePeak: 1
        )

        XCTAssertEqual(ReplayGain.appliedGainDB(mode: .album, track: track, album: album), 0)
        XCTAssertEqual(ReplayGain.appliedGainDB(mode: .album, track: track, album: nil), 6, accuracy: 0.000_001)
        XCTAssertEqual(ReplayGain.appliedGainDB(mode: .album, track: nil, album: nil), 0)
        XCTAssertEqual(ReplayGain.appliedGainDB(mode: .off, track: track, album: album), 0)
    }

    func testModeDefaultsOffAndCyclesInProductOrder() {
        XCTAssertEqual(ReplayGainMode.defaultValue, .off)
        XCTAssertEqual(ReplayGainMode.off.next, .track)
        XCTAssertEqual(ReplayGainMode.track.next, .album)
        XCTAssertEqual(ReplayGainMode.album.next, .off)
    }
}
