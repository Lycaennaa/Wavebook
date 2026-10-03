import AVFoundation
import Foundation
import WavebookCore

enum EqualizerRenderBenchmark {
    private static let durationSeconds = 10
    private static let sampleRate = 48_000.0
    private static let blockFrameCount: AVAudioFrameCount = 4_096

    static func active() async throws -> PerformanceRun {
        try await run(scenario: "equalizer-render-active", bypassed: false)
    }

    static func bypassed() async throws -> PerformanceRun {
        try await run(scenario: "equalizer-render-bypassed", bypassed: true)
    }

    private static func run(scenario: String, bypassed: Bool) async throws -> PerformanceRun {
        let totalFrameCount = Int(sampleRate * Double(durationSeconds))
        let renderBlockCount = (totalFrameCount + Int(blockFrameCount) - 1) / Int(blockFrameCount)
        return try await PerformanceBenchmark.run(
            scenario: scenario,
            workload: PerformanceWorkload(
                description: "Offline-render ten seconds of stereo audio through the 31-band AVAudioUnitEQ",
                operations: renderBlockCount,
                dimensions: [
                    "audio_seconds": durationSeconds,
                    "sample_rate_hz": Int(sampleRate),
                    "channels": 2,
                    "bands": EqualizerProfile.bandCount,
                    "frames": totalFrameCount
                ]
            ),
            prepare: {
                guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
                      let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrameCount)),
                      let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrameCount),
                      let inputChannels = inputBuffer.floatChannelData else {
                    throw PerformanceBenchmarkError.unexpectedResult("Could not allocate equalizer render buffers")
                }
                inputBuffer.frameLength = AVAudioFrameCount(totalFrameCount)
                for frame in 0..<totalFrameCount {
                    let value = Float(sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate)) * 0.25
                    inputChannels[0][frame] = value
                    inputChannels[1][frame] = value
                }

                let profile = EqualizerProfile(
                    isBypassed: bypassed,
                    bandGains: EqualizerProfile.frequencies.indices.map { index in
                        index.isMultiple(of: 2) ? 3 : -3
                    }
                )
                let equalizer = AVAudioUnitEQ(numberOfBands: EqualizerProfile.bandCount)
                equalizer.globalGain = profile.isBypassed ? 0 : Float(profile.preamp)
                for (index, band) in equalizer.bands.enumerated() {
                    band.filterType = .parametric
                    band.frequency = Float(EqualizerProfile.frequencies[index])
                    band.bandwidth = 1 / 3
                    band.gain = Float(profile.bandGains[index])
                    band.bypass = profile.isBypassed
                }

                let engine = AVAudioEngine()
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.attach(equalizer)
                engine.connect(player, to: equalizer, format: format)
                engine.connect(equalizer, to: engine.mainMixerNode, format: format)
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: blockFrameCount)
                player.scheduleBuffer(inputBuffer, at: nil, completionCallbackType: .dataPlayedBack) { _ in }
                engine.prepare()
                try engine.start()
                player.play()

                return PerformancePreparedIteration(operation: {
                    var remainingFrames = totalFrameCount
                    var outputMagnitude = 0.0
                    while remainingFrames > 0 {
                        let frameCount = AVAudioFrameCount(min(remainingFrames, Int(blockFrameCount)))
                        let status = try engine.renderOffline(frameCount, to: outputBuffer)
                        guard status == .success,
                              outputBuffer.frameLength == frameCount,
                              let outputChannels = outputBuffer.floatChannelData else {
                            throw PerformanceBenchmarkError.unexpectedResult("Equalizer offline render did not complete")
                        }
                        outputMagnitude += abs(Double(outputChannels[0][Int(frameCount) / 2]))
                        remainingFrames -= Int(frameCount)
                    }
                    guard outputMagnitude.isFinite, outputMagnitude > 0.01 else {
                        throw PerformanceBenchmarkError.unexpectedResult("Equalizer offline render returned no signal")
                    }
                }, cleanup: {
                    engine.stop()
                })
            }
        )
    }
}