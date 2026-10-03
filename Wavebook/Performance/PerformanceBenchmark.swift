import AVFoundation
import Foundation
import WavebookCore

struct PerformanceWorkload: Encodable, Equatable {
    let description: String
    let operations: Int
    let dimensions: [String: Int]
}

struct PerformanceSample: Encodable {
    let wallMs: Double
    let cpuMs: Double
    let cpuPercent: Double
    let peakRssBytes: UInt64
    let peakRssGrowthBytes: UInt64
    let residentBytes: UInt64
    let residentGrowthBytes: UInt64
    let physicalFootprintBytes: UInt64
    let physicalFootprintGrowthBytes: UInt64
    let diskBytesRead: UInt64
    let diskBytesWritten: UInt64
    let logicalWrites: UInt64?
    let pageIns: UInt64
    let energyNanojoules: UInt64?
    let averagePowerWatts: Double?
}

struct PerformanceMetrics: Encodable {
    let wallMsMedian: Double
    let cpuMsMedian: Double
    let cpuPercentMedian: Double
    let peakRssBytes: UInt64
    let peakRssGrowthBytesMedian: Double
    let residentBytesMedian: Double
    let residentGrowthBytesMedian: Double
    let physicalFootprintBytesMedian: Double
    let physicalFootprintGrowthBytesMedian: Double
    let diskBytesReadMedian: Double
    let diskBytesWrittenMedian: Double
    let logicalWritesMedian: Double?
    let pageInsMedian: Double
    let energyNanojoulesMedian: Double?
    let averagePowerWattsMedian: Double?
}

struct PerformanceRun: Encodable {
    let schemaVersion = 1
    let resourceMetricsVersion = 2
    let scenario: String
    let scenarioVersion = 1
    let workload: PerformanceWorkload
    let warmupIterations: Int
    let measuredIterations: Int
    let samples: [PerformanceSample]
    let metrics: PerformanceMetrics
}

struct PerformancePreparedIteration {
    let operation: () async throws -> Void
    let cleanup: () -> Void

    init(operation: @escaping () async throws -> Void, cleanup: @escaping () -> Void = {}) {
        self.operation = operation
        self.cleanup = cleanup
    }
}

enum PerformanceBenchmark {
    static let warmupIterations = 1
    static let measuredIterations = 5

    static func run(
        scenario: String,
        workload: PerformanceWorkload,
        warmupIterations: Int = Self.warmupIterations,
        measuredIterations: Int = Self.measuredIterations,
        prepare: () async throws -> PerformancePreparedIteration
    ) async throws -> PerformanceRun {
        for _ in 0..<warmupIterations {
            _ = try await measureIteration(prepare: prepare)
        }

        var samples: [PerformanceSample] = []
        samples.reserveCapacity(measuredIterations)
        for _ in 0..<measuredIterations {
            samples.append(try await measureIteration(prepare: prepare))
        }

        return PerformanceRun(
            scenario: scenario,
            workload: workload,
            warmupIterations: warmupIterations,
            measuredIterations: measuredIterations,
            samples: samples,
            metrics: PerformanceMetrics(
                wallMsMedian: median(samples.map(\.wallMs)),
                cpuMsMedian: median(samples.map(\.cpuMs)),
                cpuPercentMedian: median(samples.map(\.cpuPercent)),
                peakRssBytes: samples.map(\.peakRssBytes).max() ?? 0,
                peakRssGrowthBytesMedian: median(samples.map { Double($0.peakRssGrowthBytes) }),
                residentBytesMedian: median(samples.map { Double($0.residentBytes) }),
                residentGrowthBytesMedian: median(samples.map { Double($0.residentGrowthBytes) }),
                physicalFootprintBytesMedian: median(samples.map { Double($0.physicalFootprintBytes) }),
                physicalFootprintGrowthBytesMedian: median(samples.map { Double($0.physicalFootprintGrowthBytes) }),
                diskBytesReadMedian: median(samples.map { Double($0.diskBytesRead) }),
                diskBytesWrittenMedian: median(samples.map { Double($0.diskBytesWritten) }),
                logicalWritesMedian: medianIfAvailable(
                    samples.compactMap { $0.logicalWrites.map { Double($0) } },
                    sampleCount: samples.count
                ),
                pageInsMedian: median(samples.map { Double($0.pageIns) }),
                energyNanojoulesMedian: medianIfAvailable(
                    samples.compactMap { $0.energyNanojoules.map { Double($0) } },
                    sampleCount: samples.count
                ),
                averagePowerWattsMedian: medianIfAvailable(
                    samples.compactMap(\.averagePowerWatts),
                    sampleCount: samples.count
                )
            )
        )
    }

    private static func measureIteration(
        prepare: () async throws -> PerformancePreparedIteration
    ) async throws -> PerformanceSample {
        let prepared = try await prepare()
        defer { prepared.cleanup() }
        let memorySampler = ProcessMemorySampler()
        defer { memorySampler.cancel() }

        let before = try ProcessMetrics.snapshot()
        memorySampler.start(baseline: ProcessMemorySnapshot(
            residentBytes: before.residentBytes,
            physicalFootprintBytes: before.physicalFootprintBytes
        ))
        let start = DispatchTime.now().uptimeNanoseconds
        try await prepared.operation()
        let wallNanoseconds = DispatchTime.now().uptimeNanoseconds - start
        let after = try ProcessMetrics.snapshot()
        let memoryPeak = try memorySampler.finish(after: ProcessMemorySnapshot(
            residentBytes: after.residentBytes,
            physicalFootprintBytes: after.physicalFootprintBytes
        ))
        let countersAreMonotonic = after.diskBytesRead >= before.diskBytesRead
            && after.diskBytesWritten >= before.diskBytesWritten
            && after.pageIns >= before.pageIns
        let logicalWriteDelta: UInt64?
        switch (before.logicalWrites, after.logicalWrites) {
        case let (start?, end?) where end >= start:
            logicalWriteDelta = end - start
        case (nil, nil):
            logicalWriteDelta = nil
        default:
            throw PerformanceBenchmarkError.invalidResourceMeasurement
        }
        let energyDelta: UInt64?
        switch (before.energyNanojoules, after.energyNanojoules) {
        case let (start?, end?) where end >= start:
            energyDelta = end - start
        case (nil, nil):
            energyDelta = nil
        default:
            throw PerformanceBenchmarkError.invalidResourceMeasurement
        }
        guard wallNanoseconds > 0,
              after.cpuTimeNanoseconds >= before.cpuTimeNanoseconds,
              countersAreMonotonic else {
            throw PerformanceBenchmarkError.invalidResourceMeasurement
        }

        let cpuNanoseconds = after.cpuTimeNanoseconds - before.cpuTimeNanoseconds
        let wallMs = Double(wallNanoseconds) / 1_000_000
        let cpuMs = Double(cpuNanoseconds) / 1_000_000
        return PerformanceSample(
            wallMs: wallMs,
            cpuMs: cpuMs,
            cpuPercent: Double(cpuNanoseconds) / Double(wallNanoseconds) * 100,
            peakRssBytes: after.peakResidentBytes,
            peakRssGrowthBytes: memoryPeak.residentGrowthBytes,
            residentBytes: after.residentBytes,
            residentGrowthBytes: after.residentBytes > before.residentBytes
                ? after.residentBytes - before.residentBytes : 0,
            physicalFootprintBytes: after.physicalFootprintBytes,
            physicalFootprintGrowthBytes: after.physicalFootprintBytes > before.physicalFootprintBytes
                ? after.physicalFootprintBytes - before.physicalFootprintBytes : 0,
            diskBytesRead: after.diskBytesRead - before.diskBytesRead,
            diskBytesWritten: after.diskBytesWritten - before.diskBytesWritten,
            logicalWrites: logicalWriteDelta,
            pageIns: after.pageIns - before.pageIns,
            energyNanojoules: energyDelta,
            averagePowerWatts: energyDelta.map { Double($0) / Double(wallNanoseconds) }
        )
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func medianIfAvailable(_ values: [Double], sampleCount: Int) -> Double? {
        guard values.count == sampleCount else { return nil }
        return median(values)
    }
}

enum PerformanceFixtures {
    static func temporaryDirectory(named name: String) throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".tmp/wavebook-performance")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func makeWaveFile(
        sampleRate: UInt32 = 8_000,
        duration: TimeInterval = 0.1,
        amplitude: Double = 0,
        channelCount: UInt16 = 1
    ) -> Data {
        let frameCount = Int(Double(sampleRate) * duration)
        let blockAlignment = channelCount * 2
        let dataSize = UInt32(frameCount * Int(blockAlignment))
        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))
        data.append(contentsOf: Data("RIFF".utf8))
        appendLittleEndian(UInt32(36) + dataSize, to: &data)
        data.append(contentsOf: Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(channelCount, to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * UInt32(blockAlignment), to: &data)
        appendLittleEndian(blockAlignment, to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: Data("data".utf8))
        appendLittleEndian(dataSize, to: &data)

        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * 1_000 * Double(frame) / Double(sampleRate)
            let sample = Int16((sin(phase) * amplitude * Double(Int16.max)).rounded())
            for _ in 0..<channelCount {
                appendLittleEndian(sample, to: &data)
            }
        }
        return data
    }

    static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}

enum PerformanceBenchmarkError: Error {
    case invalidResourceMeasurement
    case unexpectedResult(String)
}