@preconcurrency import AVFoundation
import Darwin
import Foundation
@testable import WavebookCore
import XCTest

final class AudioMetadataReaderTests: XCTestCase {
    private let expectedReplayGainTags = [
        "REPLAYGAIN_TRACK_GAIN": "-7.25 dB",
        "REPLAYGAIN_TRACK_PEAK": "0.987654",
        "REPLAYGAIN_ALBUM_GAIN": "-6.50 dB",
        "REPLAYGAIN_ALBUM_PEAK": "1.012345",
        "R128_TRACK_GAIN": "-256",
        "R128_ALBUM_GAIN": "-512"
    ]

    func testAVFoundationReturnsExactReplayGainTagsForRequiredFormats() async throws {
        let reader = AudioMetadataReader()

        for fileExtension in ["mp3", "flac", "opus"] {
            let values = try await reader.replayGainTagValues(for: fixtureURL(fileExtension: fileExtension))
            XCTAssertEqual(values, expectedReplayGainTags, fileExtension)
        }
    }

    func testExtractedFixtureTagsUseReplayGainPrecedence() async throws {
        let reader = AudioMetadataReader()

        for fileExtension in ["mp3", "flac", "opus"] {
            let tags = try await reader.replayGainTags(for: fixtureURL(fileExtension: fileExtension))
            XCTAssertEqual(tags.track?.gain, ReplayGainGain(decibels: -7.25, source: .replayGain), fileExtension)
            XCTAssertEqual(tags.track?.samplePeak, 0.987654, fileExtension)
            XCTAssertEqual(tags.album?.gain, ReplayGainGain(decibels: -6.5, source: .replayGain), fileExtension)
            XCTAssertEqual(tags.album?.samplePeak, 1.012345, fileExtension)
        }
    }

    func testValidDuplicateID3UserTextWinsOverMalformedValue() async throws {
        let malformed = id3UserText(description: "REPLAYGAIN_TRACK_GAIN", value: "invalid")
        let valid = id3UserText(description: "REPLAYGAIN_TRACK_GAIN", value: "-7.25 dB")

        for items in [[malformed, valid], [valid, malformed]] {
            let values = try await AudioMetadataReader.replayGainTagValues(from: items)
            XCTAssertEqual(values["REPLAYGAIN_TRACK_GAIN"], "-7.25 dB")
        }
    }

    func testMetadataFieldsCapIndividualAndMergedValues() async throws {
        let oversizedTitle = String(repeating: "T", count: AudioMetadataLimits.maximumMetadataValueLength + 100)
        var items: [AVMetadataItem] = [metadataItem(key: "title", value: oversizedTitle)]
        items.append(contentsOf: (0..<(AudioMetadataLimits.maximumMergedValueCount + 10)).map {
            metadataItem(key: "artist", value: "Artist-\($0)")
        })

        let tags = try await AudioMetadataReader.tags(from: items)

        XCTAssertEqual(tags.title?.count, AudioMetadataLimits.maximumMetadataValueLength)
        XCTAssertLessThanOrEqual(tags.artistDisplay?.count ?? 0, AudioMetadataLimits.maximumMergedValueLength)
        XCTAssertEqual(
            MetadataParser.splitList(tags.artistDisplay ?? "").count,
            AudioMetadataLimits.maximumMergedValueCount
        )
    }

    func testMetadataItemCountIsBoundedBeforeExtraction() async {
        let items = (0...AudioMetadataLimits.maximumMetadataItemCount).map {
            metadataItem(key: "title", value: "Title-\($0)")
        }

        do {
            _ = try await AudioMetadataReader.tags(from: items)
            XCTFail("Expected metadata item limit")
        } catch {
            XCTAssertEqual(error as? AudioMetadataError, .tooManyMetadataItems)
        }
    }

    func testReplayGainValuesAreRetainedOnlyWithinIndividualLimit() async throws {
        let value = String(repeating: "x", count: AudioMetadataLimits.maximumMetadataValueLength + 100)
        let values = try await AudioMetadataReader.replayGainTagValues(
            from: [metadataItem(key: "REPLAYGAIN_TRACK_GAIN", value: value)]
        )

        XCTAssertEqual(values["REPLAYGAIN_TRACK_GAIN"]?.count, AudioMetadataLimits.maximumMetadataValueLength)
    }
    func testMetadataExtractionPropagatesCancellationAfterStringLoad() async throws {
        let gate = MetadataStringLoadGate()
        let item = metadataItem(key: "title", value: "Title")
        let task = Task {
            try await AudioMetadataReader.tags(from: [item], stringValueLoader: { _ in
                await gate.markStarted()
                try? await Task.sleep(for: .seconds(60))
                return "Title"
            })
        }

        await gate.waitUntilStarted()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }
    func testReplayGainMetadataExtractionPropagatesCancellationAfterStringLoad() async throws {
        let gate = MetadataStringLoadGate()
        let item = metadataItem(key: "REPLAYGAIN_TRACK_GAIN", value: "-7.25 dB")
        let task = Task {
            try await AudioMetadataReader.replayGainTagValues(
                from: [item],
                stringValueLoader: { _ in
                    await gate.markStarted()
                    try? await Task.sleep(for: .seconds(60))
                    return "-7.25 dB"
                }
            )
        }

        await gate.waitUntilStarted()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    func testPreflightRejectsOversizedID3MetadataBeforeAssetLoading() throws {
        var data = Data("ID3".utf8)
        data.append(contentsOf: [4, 0, 0])
        appendSynchsafe(UInt32(AudioMetadataLimits.maximumMetadataBytes + 1), to: &data)
        data.append(Data(count: AudioMetadataLimits.maximumMetadataBytes + 1))
        let url = try temporaryURL(data)

        XCTAssertThrowsError(try AudioMetadataPreflight.allowsAVFoundationMetadata(for: url)) { error in
            XCTAssertEqual(error as? AudioMetadataError, .metadataTooLarge)
        }
    }
    func testISOPreflightRejectsProbeExhaustionFromNonMetadataAtoms() throws {
        var data = Data()
        appendISOAtom(type: "ftyp", to: &data)
        appendISOAtom(type: "free", to: &data)
        let url = try temporaryURL(data)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var reader = BoundedFileReader(handle: handle, fileSize: UInt64(data.count), limit: UInt64(data.count))
        var budget = AudioMetadataBudget()
        try budget.addProbe(bytes: AudioMetadataLimits.maximumMetadataProbeBytes - 8)

        XCTAssertThrowsError(try AudioMetadataISOValidation.validate(from: &reader, budget: &budget)) { error in
            XCTAssertEqual(error as? AudioMetadataError, .metadataTooLarge)
        }
    }

    func testPreflightDoesNotBoundLargeNonMetadataPayloadByProbeLimit() throws {
        var data = Data()
        appendISOAtom(type: "ftyp", to: &data)
        appendISOAtom(
            type: "mdat",
            payloadLength: Int(AudioMetadataLimits.maximumMetadataProbeBytes) + 1,
            to: &data
        )
        let url = try temporaryURL(data)

        XCTAssertTrue(try AudioMetadataPreflight.allowsAVFoundationMetadata(for: url))
    }

    func testPreflightFailsClosedForMissingInput() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".test-tmp/missing-" + UUID().uuidString)
        XCTAssertFalse(try AudioMetadataPreflight.allowsAVFoundationMetadata(for: url))
    }
    func testPreflightFailsClosedWhenResourceProbeFails() throws {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/audio.mp3"))
        XCTAssertFalse(try AudioMetadataPreflight.allowsAVFoundationMetadata(for: url))
    }

    func testPreflightFailsClosedForEmptyRegularFile() throws {
        let url = try temporaryURL(Data())
        XCTAssertFalse(try AudioMetadataPreflight.allowsAVFoundationMetadata(for: url))
    }

    func testPreflightFailsClosedForDirectory() throws {
        let url = try temporaryDirectory()
        XCTAssertFalse(try AudioMetadataPreflight.allowsAVFoundationMetadata(for: url))
    }

    func testPreflightFailsClosedForFIFO() throws {
        let directory = try temporaryDirectory()
        let url = directory.appending(path: "metadata.fifo")
        let result = url.path.withCString { path in
            mkfifo(path, 0o600)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(try AudioMetadataPreflight.allowsAVFoundationMetadata(for: url))
    }

    private func metadataItem(key: String, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = key as NSString
        item.value = value as NSString
        return item
    }

    private func temporaryURL(_ data: Data) throws -> URL {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".test-tmp")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appending(path: "metadata-" + UUID().uuidString + ".bin")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".test-tmp")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appending(path: "directory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixtureURL(fileExtension: String) throws -> URL {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: AudioMetadataReaderTests.self)
        #endif
        return try XCTUnwrap(
            bundle.url(forResource: "replaygain-gate", withExtension: fileExtension, subdirectory: "Fixtures")
                ?? bundle.url(forResource: "replaygain-gate", withExtension: fileExtension)
        )
    }

    private func id3UserText(description: String, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .id3
        item.key = "userText" as NSString
        item.identifier = .id3MetadataUserText
        item.value = value as NSString
        item.extraAttributes = [.info: description as NSString]
        return item
    }

    private func appendISOAtom(type: String, payloadLength: Int = 0, to data: inout Data) {
        let typeBytes = Array(type.utf8)
        precondition(typeBytes.count == 4)
        guard let size = UInt32(exactly: 8 + payloadLength) else {
            preconditionFailure("Payload size exceeds UInt32")
        }
        data.append(UInt8(truncatingIfNeeded: size >> 24))
        data.append(UInt8(truncatingIfNeeded: size >> 16))
        data.append(UInt8(truncatingIfNeeded: size >> 8))
        data.append(UInt8(truncatingIfNeeded: size))
        data.append(contentsOf: typeBytes)
        data.append(Data(repeating: 0, count: payloadLength))
    }

    private func appendSynchsafe(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 21) & 0x7F))
        data.append(UInt8((value >> 14) & 0x7F))
        data.append(UInt8((value >> 7) & 0x7F))
        data.append(UInt8(value & 0x7F))
    }

}
private actor MetadataStringLoadGate {
    private var hasStarted = false

    func markStarted() {
        hasStarted = true
    }

    func waitUntilStarted() async {
        while !hasStarted {
            await Task.yield()
        }
    }
}
