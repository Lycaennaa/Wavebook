import Foundation
import WavebookCore

enum LyricsBenchmark {
    private static let lineCount = 5_000
    private static let sidecarFileCount = 32
    private static let timelineLookupCount = 50_000

    static func parse() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "lyrics-parse",
            workload: PerformanceWorkload(
                description: "Parse a synchronized 5,000-line LRC lyric sheet",
                operations: 1,
                dimensions: ["lines": lineCount]
            ),
            prepare: {
                let source = makeLyrics(lineCount: lineCount)
                return PerformancePreparedIteration {
                    let lyrics = try LRCLyrics.parse(source)
                    guard lyrics.lines.count == lineCount else {
                        throw PerformanceBenchmarkError.unexpectedResult("LRC parser returned an unexpected line count")
                    }
                }
            }
        )
    }

    static func sidecarRead() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "lyrics-sidecar",
            workload: PerformanceWorkload(
                description: "Resolve, read, and parse same-folder LRC sidecars",
                operations: sidecarFileCount,
                dimensions: ["audio_files": sidecarFileCount, "lyric_lines_per_file": 1]
            ),
            prepare: {
                let directory = try PerformanceFixtures.temporaryDirectory(named: "lyrics-sidecar")
                var audioFiles: [URL] = []
                for index in 0..<sidecarFileCount {
                    let audioURL = directory.appending(path: "Track-\(index).wav")
                    try Data().write(to: audioURL)
                    try "[00:00.00]Synthetic lyric".write(
                        to: audioURL.deletingPathExtension().appendingPathExtension("lrc"),
                        atomically: true,
                        encoding: .utf8
                    )
                    audioFiles.append(audioURL)
                }
                let loader = LRCLyricsLoader()
                return PerformancePreparedIteration(operation: {
                    for audioURL in audioFiles {
                        guard let lyrics = try await loader.lyrics(for: audioURL, libraryRoots: []),
                              lyrics.lines.count == 1 else {
                            throw PerformanceBenchmarkError.unexpectedResult("LRC sidecar was not resolved")
                        }
                    }
                }, cleanup: {
                    try? FileManager.default.removeItem(at: directory)
                })
            }
        )
    }

    static func timelineLookup() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "lyrics-timeline",
            workload: PerformanceWorkload(
                description: "Binary-search active lyric line on a 5,000-line timeline",
                operations: timelineLookupCount,
                dimensions: ["lines": lineCount]
            ),
            prepare: {
                let lyrics = try LRCLyrics.parse(makeLyrics(lineCount: lineCount))
                return PerformancePreparedIteration {
                    var checksum = 0
                    for index in 0..<timelineLookupCount {
                        checksum += lyrics.lineIndex(at: TimeInterval(index % lineCount)) ?? 0
                    }
                    guard checksum > 0 else {
                        throw PerformanceBenchmarkError.unexpectedResult("LRC timeline lookup returned no lines")
                    }
                }
            }
        )
    }

    private static func makeLyrics(lineCount: Int) -> String {
        (0..<lineCount).map { index in
            let minutes = index / 60
            let seconds = index % 60
            return String(format: "[%02d:%02d.00] Synthetic lyric line %05d", minutes, seconds, index)
        }.joined(separator: "\n")
    }
}