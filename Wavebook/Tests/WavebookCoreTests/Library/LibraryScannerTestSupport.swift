import Foundation
@testable import WavebookCore
import XCTest

final class LibraryScannerTests: XCTestCase {

    func makeRoot() throws -> URL {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".test-tmp")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    func writeOversizedID3(to url: URL) throws {
        var data = Data("ID3".utf8)
        data.append(contentsOf: [4, 0, 0])
        appendSynchsafe(UInt32(AudioMetadataLimits.maximumMetadataBytes + 1), to: &data)
        data.append(Data(count: AudioMetadataLimits.maximumMetadataBytes + 1))
        try data.write(to: url)
    }

    func appendSynchsafe(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 21) & 0x7F))
        data.append(UInt8((value >> 14) & 0x7F))
        data.append(UInt8((value >> 7) & 0x7F))
        data.append(UInt8(value & 0x7F))
    }

    func writeWAV(to url: URL) throws {
        let sampleCount: UInt32 = 800
        let dataSize = sampleCount * 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(36) + dataSize, to: &data)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(8_000), to: &data)
        appendLittleEndian(UInt32(16_000), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendLittleEndian(dataSize, to: &data)
        data.append(Data(count: Int(dataSize)))
        try data.write(to: url)
    }

    func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
