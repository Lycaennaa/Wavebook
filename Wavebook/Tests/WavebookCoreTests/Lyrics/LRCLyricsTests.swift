import Foundation
@testable import WavebookCore
import XCTest

extension LRCLyricsTests {
    func testParsesTimestampsGlobalOffsetAndCurrentLine() throws {
        let lyrics = try LRCLyrics.parse("""
        [ar:Artist]
        [00:01.00]First line
        [00:02.50][00:03,25]Second line
        [offset:500]
        """)

        XCTAssertEqual(lyrics.lines.map(\.time), [1.5, 3.0, 3.75])
        XCTAssertEqual(lyrics.lines.map(\.text), ["First line", "Second line", "Second line"])
        XCTAssertNil(lyrics.lineIndex(at: 1.49))
        XCTAssertEqual(lyrics.lineIndex(at: 1.11, leadTime: 0.4), 0)
        XCTAssertEqual(lyrics.lineIndex(at: 1.5), 0)
        XCTAssertEqual(lyrics.lineIndex(at: 2.61, leadTime: 0.4), 1)
        XCTAssertEqual(lyrics.lineIndex(at: 3.1), 1)
        XCTAssertEqual(lyrics.lineIndex(at: 100), 2)
    }

    func testMatchKeyIsCaseInsensitive() {
        let upper = URL(fileURLWithPath: "/Music/BJÖRK.LRC")
        let lower = URL(fileURLWithPath: "/Music/björk.flac")
        XCTAssertEqual(LRCLyrics.matchKey(forFileURL: upper), LRCLyrics.matchKey(forFileURL: lower))
    }
    func testMatchKeyIncludesParentDirectory() {
        let first = URL(fileURLWithPath: "/Music/One/Song.flac")
        let second = URL(fileURLWithPath: "/Music/Two/Song.lrc")

        XCTAssertNotEqual(LRCLyrics.matchKey(forFileURL: first), LRCLyrics.matchKey(forFileURL: second))
    }
    func testCombinesLyricsAtSameTimestamp() throws {
        let lyrics = try LRCLyrics.parse("""
        [00:01.00]Original
        [00:01.00]Translation
        """)

        XCTAssertEqual(lyrics.lines, [LRCLyricLine(time: 1, text: "Original\nTranslation")])
    }
    func testSkipsPlaceholderOnlyFirstLRCLine() throws {
        let blankPlaceholder = try LRCLyrics.parse("[00:00]\n[00:02]First line")
        XCTAssertEqual(blankPlaceholder.lines, [LRCLyricLine(time: 2, text: "First line")])

        let notePlaceholder = try LRCLyrics.parse("[00:00]♪\n[00:02]First line")
        XCTAssertEqual(notePlaceholder.lines, [LRCLyricLine(time: 2, text: "First line")])
    }

    func testRejectsDuplicateTimestampAmplificationBeforeMerging() {
        let duplicateTimestampCount = 10_000
        let repeatedText = String(repeating: "x", count: 256)
        let source = String(repeating: "[00:00]", count: duplicateTimestampCount) + repeatedText

        XCTAssertLessThan(source.utf8.count, 2 * 1_024 * 1_024)
        XCTAssertThrowsError(try LRCLyrics.parse(source)) { error in
            XCTAssertEqual(error as? LRCParseError, .tooManyBytes)
        }
    }

    func testRejectsTextWithoutTimedLyrics() {
        XCTAssertThrowsError(try LRCLyrics.parse("[ar:Artist]\nPlain text")) { error in
            XCTAssertEqual(error as? LRCParseError, .noTimedLyrics)
        }
    }

    func testInstrumentalMarkerRemainsCaseInsensitiveAndLineBounded() throws {
        let marker = try LRCLyrics.parse("[AU: INSTRUMENTAL]\n[00:01]Line")
        XCTAssertTrue(marker.isInstrumental)

        let embedded = try LRCLyrics.parse("[00:01]Text [au: instrumental]")
        XCTAssertFalse(embedded.isInstrumental)
    }

    func testExtremeMinutesAndNonFiniteOffsetsDoNotTrapOrCorruptTime() throws {
        let extreme = try LRCLyrics.parse("[\(Int.max):00]Far future")
        XCTAssertTrue(extreme.lines[0].time.isFinite)

        let nonFiniteOffset = try LRCLyrics.parse("[00:01]Line\n[offset:inf]")
        XCTAssertEqual(nonFiniteOffset.lines[0].time, 1)
    }
    func testCancelledParsingThrowsCancellationInsteadOfParseError() async {
        let task = Task {
            await Task.yield()
            return try LRCLyrics.parse("not timed")
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPlaybackBarPreviewCountsDownToExactTimestamp() {
        let lyrics = LRCLyrics(lines: [LRCLyricLine(time: 12.6, text: "First")])

        let before = LyricsPlaybackPreview(lyrics: lyrics, elapsed: 8.2)
        guard case let .waiting(firstLine, timeUntil) = before else {
            return XCTFail("Expected a waiting preview")
        }
        XCTAssertEqual(firstLine, lyrics.lines[0])
        XCTAssertEqual(timeUntil, 4.4, accuracy: 0.000_001)
        XCTAssertFalse(before.isCurrent)

        let atTimestamp = LyricsPlaybackPreview(lyrics: lyrics, elapsed: 12.6)
        XCTAssertEqual(atTimestamp, .current(lyrics.lines[0]))
        XCTAssertTrue(atTimestamp.isCurrent)
    }

    func testPlaybackBarPreviewGreysUntimestampedLyricsAndHandlesSeekBack() {
        let plain = LRCLyrics(
            lines: [LRCLyricLine(time: 0, text: "Plain")],
            isSynchronized: false
        )
        let plainPreview = LyricsPlaybackPreview(lyrics: plain, elapsed: 42)
        XCTAssertEqual(plainPreview, .untimed(plain.lines[0]))
        XCTAssertFalse(plainPreview.isCurrent)

        let synced = LRCLyrics(lines: [LRCLyricLine(time: 4, text: "Line")])
        XCTAssertEqual(
            LyricsPlaybackPreview(lyrics: synced, elapsed: 5),
            .current(synced.lines[0])
        )

        let rewound = LyricsPlaybackPreview(lyrics: synced, elapsed: 0)
        guard case let .waiting(firstLine, timeUntil) = rewound else {
            return XCTFail("Expected a waiting preview after seeking back")
        }
        XCTAssertEqual(firstLine, synced.lines[0])
        XCTAssertEqual(timeUntil, 4)
        XCTAssertFalse(rewound.isCurrent)
    }

    func testPlaybackPreviewPreservesInstrumentalSemantics() throws {
        let instrumental = try LRCLyrics.parse("[au: instrumental]")
        XCTAssertTrue(instrumental.isInstrumental)
        XCTAssertEqual(
            LyricsPlaybackPreview(lyrics: instrumental, elapsed: 12),
            .instrumental
        )

        let literal = LRCLyrics(
            lines: [LRCLyricLine(time: 0, text: "Instrumental")],
            isSynchronized: false
        )
        XCTAssertEqual(
            LyricsPlaybackPreview(lyrics: literal, elapsed: 12),
            .untimed(literal.lines[0])
        )
    }

}
