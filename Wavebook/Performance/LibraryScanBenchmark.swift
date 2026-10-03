import Foundation
import WavebookCore

enum LibraryScanBenchmark {
    static func run() async throws -> PerformanceRun {
        try await run(scenario: "library-scan", trackCount: 200, measuredIterations: 5)
    }

    static func medium() async throws -> PerformanceRun {
        try await run(scenario: "library-scan-medium", trackCount: 1_000, measuredIterations: 2)
    }

    static func large() async throws -> PerformanceRun {
        try await run(scenario: "library-scan-large", trackCount: 2_000, measuredIterations: 3)
    }
    static func rescanLarge() async throws -> PerformanceRun {
        let scenario = "library-rescan-large"
        let trackCount = 2_000
        return try await PerformanceBenchmark.run(
            scenario: scenario,
            workload: PerformanceWorkload(
                description: "Rescan unchanged synthetic WAV files in a populated catalog",
                operations: 1,
                dimensions: ["tracks": trackCount, "sample_rate_hz": 8_000, "duration_ms": 100]
            ),
            measuredIterations: 3,
            prepare: {
                let library = try await prepareRescanLibrary(scenario: scenario, trackCount: trackCount)
                return PerformancePreparedIteration(operation: {
                    let result = try await library.scanner.scan(root: library.libraryRoot, database: library.database)
                    guard result.tracks.count == trackCount else {
                        throw PerformanceBenchmarkError.unexpectedResult(
                            "Library rescan returned \(result.tracks.count) tracks"
                        )
                    }
                }, cleanup: {
                    try? FileManager.default.removeItem(at: library.iterationRoot)
                })
            }
        )
    }


    static func oneChangeLarge() async throws -> PerformanceRun {
        let scenario = "library-one-change-large"
        let trackCount = 2_000
        return try await PerformanceBenchmark.run(
            scenario: scenario,
            workload: PerformanceWorkload(
                description: "Rescan a populated synthetic WAV catalog with one changed file",
                operations: 1,
                dimensions: ["tracks": trackCount, "changed_tracks": 1, "sample_rate_hz": 8_000]
            ),
            measuredIterations: 3,
            prepare: {
                let library = try await prepareRescanLibrary(scenario: scenario, trackCount: trackCount)
                do {
                    try FileManager.default.setAttributes(
                        [.modificationDate: Date(timeIntervalSince1970: 978_307_200)],
                        ofItemAtPath: library.libraryRoot.appending(path: "Track-0.wav").path
                    )
                } catch {
                    try? FileManager.default.removeItem(at: library.iterationRoot)
                    throw error
                }
                return PerformancePreparedIteration(operation: {
                    let result = try await library.scanner.scan(root: library.libraryRoot, database: library.database)
                    guard result.tracks.count == trackCount else {
                        throw PerformanceBenchmarkError.unexpectedResult(
                            "Incremental library scan returned \(result.tracks.count) tracks"
                        )
                    }
                }, cleanup: {
                    try? FileManager.default.removeItem(at: library.iterationRoot)
                })
            }
        )
    }

    private struct PreparedRescanLibrary {
        let iterationRoot: URL
        let libraryRoot: URL
        let database: LibraryDatabase
        let scanner: LibraryScanner
    }

    private static func prepareRescanLibrary(
        scenario: String,
        trackCount: Int
    ) async throws -> PreparedRescanLibrary {
        let iterationRoot = try PerformanceFixtures.temporaryDirectory(named: scenario)
        do {
            let libraryRoot = iterationRoot.appending(path: "Library")
            try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            let fixture = PerformanceFixtures.makeWaveFile()
            for index in 0..<trackCount {
                try fixture.write(to: libraryRoot.appending(path: "Track-\(index).wav"))
            }
            let database = try LibraryDatabase(path: iterationRoot.appending(path: "Library.sqlite").path)
            let scanner = LibraryScanner()
            let initialResult = try await scanner.scan(root: libraryRoot, database: database)
            guard initialResult.tracks.count == trackCount else {
                throw PerformanceBenchmarkError.unexpectedResult(
                    "Initial library scan returned \(initialResult.tracks.count) tracks"
                )
            }
            return PreparedRescanLibrary(
                iterationRoot: iterationRoot,
                libraryRoot: libraryRoot,
                database: database,
                scanner: scanner
            )
        } catch {
            try? FileManager.default.removeItem(at: iterationRoot)
            throw error
        }
    }

    private static func run(
        scenario: String,
        trackCount: Int,
        measuredIterations: Int
    ) async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: scenario,
            workload: PerformanceWorkload(
                description: "Synthetic mono PCM WAV library scan",
                operations: 1,
                dimensions: ["tracks": trackCount, "sample_rate_hz": 8_000, "duration_ms": 100]
            ),
            measuredIterations: measuredIterations,
            prepare: {
                let iterationRoot = try PerformanceFixtures.temporaryDirectory(named: scenario)
                let libraryRoot = iterationRoot.appending(path: "Library")
                try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
                let fixture = PerformanceFixtures.makeWaveFile()
                for index in 0..<trackCount {
                    try fixture.write(to: libraryRoot.appending(path: "Track-\(index).wav"))
                }

                let database = try LibraryDatabase(path: iterationRoot.appending(path: "Library.sqlite").path)
                let scanner = LibraryScanner()
                return PerformancePreparedIteration(operation: {
                    let result = try await scanner.scan(root: libraryRoot, database: database)
                    guard result.tracks.count == trackCount else {
                        throw PerformanceBenchmarkError.unexpectedResult(
                            "Library scan returned \(result.tracks.count) tracks"
                        )
                    }
                }, cleanup: {
                    try? FileManager.default.removeItem(at: iterationRoot)
                })
            }
        )
    }
}