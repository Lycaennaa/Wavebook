import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
@testable import WavebookCore
import XCTest

final class ReplayGainAnalyzerTests: XCTestCase {

    func makeDecoderMeasurement() throws -> ReplayGainAlbumDecoder.DecodedMeasurement {
        let state = try LibEBUR128State(channelCount: 1, sampleRate: 48_000)
        let samples = [Float](repeating: 0.5, count: 48_000 * 3)
        try samples.withUnsafeBufferPointer { buffer in
            try state.addFramesFloat(buffer, frameCount: samples.count)
        }
        return ReplayGainAlbumDecoder.DecodedMeasurement(
            snapshot: state.snapshot(),
            samplePeak: 0.5
        )
    }

    func makeDatabase(root: URL, url: URL) throws -> LibraryDatabase {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        _ = try database.save(
            track: Track(
                path: url.path,
                title: url.deletingPathExtension().lastPathComponent,
                artistDisplay: "Artist",
                albumTitle: "Album",
                albumArtist: "Artist",
                genreDisplay: "",
                duration: 3,
                format: url.pathExtension
            ),
            rootID: rootID
        )
        return database
    }

    func fixtureURL(fileExtension: String) throws -> URL {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: ReplayGainAnalyzerTests.self)
        #endif
        return try XCTUnwrap(
            bundle.url(forResource: "replaygain-gate", withExtension: fileExtension, subdirectory: "Fixtures")
                ?? bundle.url(forResource: "replaygain-gate", withExtension: fileExtension)
        )
    }

    func makeRoot() throws -> URL {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".test-tmp")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func makeSparseWAV(
        frameCount: UInt32,
        in directory: URL? = nil,
        sampleRate: UInt32 = 48_000,
        channelCount: UInt16 = 2
    ) throws -> URL {
        let directory = try directory ?? makeRoot()
        let url = directory.appending(path: "\(UUID().uuidString).wav")
        let bytesPerSample: UInt16 = 2
        let blockAlignment = channelCount * bytesPerSample
        let (dataSize, overflow) = frameCount.multipliedReportingOverflow(by: UInt32(blockAlignment))
        guard !overflow else {
            throw NSError(domain: "ReplayGainAnalyzerTests", code: 1)
        }

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(36) + dataSize, to: &header)
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &header)
        appendLittleEndian(UInt16(1), to: &header)
        appendLittleEndian(channelCount, to: &header)
        appendLittleEndian(sampleRate, to: &header)
        appendLittleEndian(sampleRate * UInt32(blockAlignment), to: &header)
        appendLittleEndian(blockAlignment, to: &header)
        appendLittleEndian(UInt16(16), to: &header)
        header.append(contentsOf: Array("data".utf8))
        appendLittleEndian(dataSize, to: &header)
        try header.write(to: url)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(header.count) + UInt64(dataSize) - 1)
        try handle.write(contentsOf: Data([0]))
        return url
    }

    func makeSineWAV(
        in directory: URL? = nil,
        sampleRate: UInt32 = 48_000,
        duration: TimeInterval = 3,
        amplitude: Double
    ) throws -> URL {
        let directory = try directory ?? makeRoot()
        let url = directory.appending(path: "\(UUID().uuidString).wav")
        let channelCount: UInt16 = 2
        let frameCount = UInt32(Double(sampleRate) * duration)
        let bytesPerSample = UInt16(2)
        let blockAlignment = channelCount * bytesPerSample
        let dataSize = frameCount * UInt32(blockAlignment)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(36) + dataSize, to: &data)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(channelCount, to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * UInt32(blockAlignment), to: &data)
        appendLittleEndian(blockAlignment, to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendLittleEndian(dataSize, to: &data)

        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * 1_000 * Double(frame) / Double(sampleRate)
            let sample = Int16((sin(phase) * amplitude * Double(Int16.max)).rounded())
            appendLittleEndian(sample, to: &data)
            appendLittleEndian(sample, to: &data)
        }
        try data.write(to: url)
        return url
    }

    func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}

final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAt: Int
    private var count = 0

    init(cancelAt: Int) {
        self.cancelAt = cancelAt
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if count >= cancelAt {
            throw CancellationError()
        }
    }
}

final class FileMutationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let mutateAt: Int
    private var count = 0

    init(url: URL, mutateAt: Int) {
        self.url = url
        self.mutateAt = mutateAt
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if count == mutateAt {
            try Data("changed during analysis".utf8).write(to: url)
        }
    }
}
