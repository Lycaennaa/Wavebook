import Foundation

enum WaveformLoadBenchmark {
    private static let durationSeconds = 30
    private static let frameCount = 1_440_000
    private static let repeatedLoadCount = 5

    static func singleLoad() async throws -> PerformanceRun {
        try await load(repetitions: 1, scenario: "waveform-disk-load")
    }

    static func repeatedLoad() async throws -> PerformanceRun {
        try await load(repetitions: repeatedLoadCount, scenario: "waveform-repeated-load")
    }

    private static func load(repetitions: Int, scenario: String) async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: scenario,
            workload: PerformanceWorkload(
                description: repetitions == 1
                    ? "Load and bin a 30-second stereo WAV waveform from one path"
                    : "Load and bin the same 30-second stereo WAV waveform \(repetitions) sequential times",
                operations: repetitions,
                dimensions: [
                    "duration_seconds": durationSeconds,
                    "frames": frameCount,
                    "bins": PlaybackWaveformLoader.binCount,
                    "loads": repetitions
                ]
            ),
            prepare: {
                let directory = try PerformanceFixtures.temporaryDirectory(named: scenario)
                let audioURL = directory.appending(path: "Waveform.wav")
                let audioData = PerformanceFixtures.makeWaveFile(
                    sampleRate: 48_000,
                    duration: TimeInterval(durationSeconds),
                    amplitude: 0.5,
                    channelCount: 2
                )
                try audioData.write(to: audioURL)
                return PerformancePreparedIteration(operation: {
                    var referencePeaks: [Float]?
                    for _ in 0..<repetitions {
                        let peaks = try PlaybackWaveformLoader.load(from: audioURL)
                        guard peaks.count == PlaybackWaveformLoader.binCount,
                              peaks.contains(where: { $0 > 0.4 }) else {
                            throw PerformanceBenchmarkError.unexpectedResult("Waveform loader returned invalid peaks")
                        }
                        if let referencePeaks, peaks != referencePeaks {
                            throw PerformanceBenchmarkError.unexpectedResult("Repeated waveform loads returned different peaks")
                        }
                        referencePeaks = peaks
                    }
                }, cleanup: {
                    try? FileManager.default.removeItem(at: directory)
                })
            }
        )
    }
}