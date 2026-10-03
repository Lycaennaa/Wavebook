import Foundation
import XCTest

func makeTestWAV(for testCase: XCTestCase, samples: [Int16], sampleRate: UInt32 = 8_000) throws -> URL {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".test-tmp")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "\(UUID().uuidString).wav")
    testCase.addTeardownBlock {
        try? FileManager.default.removeItem(at: url)
    }

    let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
    var data = Data()
    data.append(contentsOf: Array("RIFF".utf8))
    appendLittleEndian(UInt32(36) + dataSize, to: &data)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(sampleRate * UInt32(MemoryLayout<Int16>.size), to: &data)
    appendLittleEndian(UInt16(MemoryLayout<Int16>.size), to: &data)
    appendLittleEndian(UInt16(16), to: &data)
    data.append(contentsOf: Array("data".utf8))
    appendLittleEndian(dataSize, to: &data)
    for sample in samples {
        appendLittleEndian(sample, to: &data)
    }
    try data.write(to: url)
    return url
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}
