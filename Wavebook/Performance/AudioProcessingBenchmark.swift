import AVFoundation
import AppKit
import Foundation
import WavebookCore

enum AudioProcessingBenchmark {
    private static let metadataFileCount = 12
    private static let replayGainDurationSeconds = 3
    private static let waveformFrameCount = 240_000
    private static let waveformDrawCount = 100
    private static let equalizerApplyCount = 1_000

    static func metadataRead() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "metadata-read",
            workload: PerformanceWorkload(
                description: "AVFoundation metadata and duration reads from PCM WAV files",
                operations: metadataFileCount,
                dimensions: ["files": metadataFileCount, "duration_ms": 100]
            ),
            prepare: {
                let directory = try PerformanceFixtures.temporaryDirectory(named: "metadata-read")
                let audioData = PerformanceFixtures.makeWaveFile()
                var files: [URL] = []
                for index in 0..<metadataFileCount {
                    let url = directory.appending(path: "Track-\(index).wav")
                    try audioData.write(to: url)
                    files.append(url)
                }
                let reader = AudioMetadataReader()
                return PerformancePreparedIteration(operation: {
                    for url in files {
                        let track = try await reader.track(for: url)
                        guard track.duration > 0 else {
                            throw PerformanceBenchmarkError.unexpectedResult("Metadata reader returned zero duration")
                        }
                    }
                }, cleanup: {
                    try? FileManager.default.removeItem(at: directory)
                })
            }
        )
    }

    static func replayGainMeasure() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "replaygain-measure",
            workload: PerformanceWorkload(
                description: "Decode and measure a 3-second stereo PCM WAV",
                operations: 1,
                dimensions: ["duration_seconds": replayGainDurationSeconds, "sample_rate_hz": 48_000, "channels": 2]
            ),
            prepare: {
                let directory = try PerformanceFixtures.temporaryDirectory(named: "replaygain")
                let audioURL = directory.appending(path: "Sine.wav")
                let audioData = PerformanceFixtures.makeWaveFile(
                    sampleRate: 48_000,
                    duration: TimeInterval(replayGainDurationSeconds),
                    amplitude: 0.5,
                    channelCount: 2
                )
                try audioData.write(to: audioURL)
                let analyzer = ReplayGainAnalyzer()
                return PerformancePreparedIteration(operation: {
                    let measurement = try analyzer.measure(url: audioURL)
                    guard measurement.integratedLUFS.isFinite, measurement.samplePeak > 0 else {
                        throw PerformanceBenchmarkError.unexpectedResult("ReplayGain measurement was invalid")
                    }
                }, cleanup: {
                    try? FileManager.default.removeItem(at: directory)
                })
            }
        )
    }

    private static let replayGainAlbumTrackCount = 10

    static func replayGainAlbumMeasure() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "replaygain-album-measure",
            workload: PerformanceWorkload(
                description: "Decode and measure ten 3-second stereo PCM WAV tracks",
                operations: replayGainAlbumTrackCount,
                dimensions: ["tracks": replayGainAlbumTrackCount, "duration_seconds_per_track": replayGainDurationSeconds]
            ),
            prepare: {
                let directory = try PerformanceFixtures.temporaryDirectory(named: "replaygain-album")
                let audioData = PerformanceFixtures.makeWaveFile(
                    sampleRate: 48_000,
                    duration: TimeInterval(replayGainDurationSeconds),
                    amplitude: 0.5,
                    channelCount: 2
                )
                var urls: [URL] = []
                for index in 0..<replayGainAlbumTrackCount {
                    let url = directory.appending(path: "Track-\(index).wav")
                    try audioData.write(to: url)
                    urls.append(url)
                }
                let analyzer = ReplayGainAnalyzer()
                return PerformancePreparedIteration(operation: {
                    let measurement = try analyzer.measureAlbum(urls: urls)
                    guard measurement.integratedLUFS.isFinite, measurement.samplePeak > 0 else {
                        throw PerformanceBenchmarkError.unexpectedResult("ReplayGain album measurement was invalid")
                    }
                }, cleanup: {
                    try? FileManager.default.removeItem(at: directory)
                })
            }
        )
    }

    static func waveformPeaks() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "waveform-peaks",
            workload: PerformanceWorkload(
                description: "Read stereo PCM peaks across an in-memory waveform buffer",
                operations: waveformFrameCount,
                dimensions: ["frames": waveformFrameCount, "channels": 2, "sample_rate_hz": 48_000]
            ),
            prepare: {
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
                guard let format,
                      let buffer = AVAudioPCMBuffer(
                        pcmFormat: format,
                        frameCapacity: AVAudioFrameCount(waveformFrameCount)
                      ),
                      let channelData = buffer.floatChannelData,
                      let reader = AudioPCMBufferReader(buffer: buffer) else {
                    throw PerformanceBenchmarkError.unexpectedResult("Could not allocate waveform buffer")
                }
                buffer.frameLength = AVAudioFrameCount(waveformFrameCount)
                for frame in 0..<waveformFrameCount {
                    let value = Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000)) * 0.7
                    channelData[0][frame] = value
                    channelData[1][frame] = -value
                }

                return PerformancePreparedIteration {
                    var peakCount = 0
                    for frame in 0..<waveformFrameCount where reader.peak(at: frame) > 0.5 {
                        peakCount += 1
                    }
                    guard peakCount > 0 else {
                        throw PerformanceBenchmarkError.unexpectedResult("Waveform peak pass returned no signal")
                    }
                }
            }
        )
    }
    private static let equalizerImportCount = 1_000

    static func equalizerProfileImport() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "equalizer-profile-import",
            workload: PerformanceWorkload(
                description: "Import 1,000 synthetic 31-band equalizer profiles",
                operations: equalizerImportCount * EqualizerProfile.bandCount,
                dimensions: ["profiles": equalizerImportCount, "bands_per_profile": EqualizerProfile.bandCount]
            ),
            prepare: {
                let source = EqualizerProfile.frequencies.enumerated().map { index, frequency in
                    "\(frequency),\(index % 13 - 6)"
                }.joined(separator: "\n")
                let baseProfile = EqualizerProfile.flat()
                return PerformancePreparedIteration {
                    var checksum = 0.0
                    for _ in 0..<equalizerImportCount {
                        let profile = try baseProfile.applyingImportedBands(source)
                        checksum += profile.bandGains[0]
                    }
                    guard checksum != 0 else {
                        throw PerformanceBenchmarkError.unexpectedResult("Equalizer profile import did no work")
                    }
                }
            }
        )
    }



    static func waveformDraw() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "waveform-draw",
            workload: PerformanceWorkload(
                description: "Draw 100 1,200-peak playback waveforms into an offscreen bitmap",
                operations: waveformDrawCount * PlaybackWaveformLoader.binCount,
                dimensions: ["draws": waveformDrawCount, "peaks": PlaybackWaveformLoader.binCount, "width": 1_200]
            ),
            prepare: {
                let peaks = (0..<PlaybackWaveformLoader.binCount).map { index in
                    Float(abs(sin(Double(index) * 0.037)))
                }
                try Self.validateWaveformRendering(peaks)
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: 1_200,
                    pixelsHigh: 400,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ) else {
                    throw PerformanceBenchmarkError.unexpectedResult("Could not allocate waveform drawing bitmap")
                }
                let context = NSGraphicsContext(bitmapImageRep: bitmap)
                let options = PlaybackWaveformDrawOptions(
                    duration: 180,
                    elapsed: 90,
                    viewportStart: 0,
                    viewportEnd: 180,
                    skipSegments: [],
                    draftStart: nil,
                    draftEnd: nil,
                    activeHandle: nil,
                    isLoading: false,
                    loadFailed: false
                )
                let plotRect = NSRect(x: 0, y: 0, width: 1_200, height: 400)
                return PerformancePreparedIteration {
                    NSGraphicsContext.saveGraphicsState()
                    defer { NSGraphicsContext.restoreGraphicsState() }
                    NSGraphicsContext.current = context
                    for _ in 0..<waveformDrawCount {
                        autoreleasepool {
                            PlaybackWaveformRenderer.draw(in: plotRect, peaks: peaks, options: options)
                        }
                    }
                }
            }
        )
    }

    private static func validateWaveformRendering(_ peaks: [Float]) throws {
        let width = 600
        let height = 200
        guard let referenceBitmap = makeWaveformBitmap(width: width, height: height),
              let optimizedBitmap = makeWaveformBitmap(width: width, height: height) else {
            throw PerformanceBenchmarkError.unexpectedResult("Could not allocate waveform comparison bitmaps")
        }
        let plotRect = NSRect(x: 0, y: 0, width: width, height: height)
        guard let referencePixels = referenceBitmap.bitmapData,
              let optimizedPixels = optimizedBitmap.bitmapData else {
            throw PerformanceBenchmarkError.unexpectedResult("Waveform comparison bitmaps had no pixel data")
        }
        let byteCount = referenceBitmap.bytesPerRow * referenceBitmap.pixelsHigh
        for index in 0..<byteCount {
            referencePixels[index] = 0
            optimizedPixels[index] = 0
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: referenceBitmap)
        drawReferenceWaveformPeaks(peaks, duration: 180, viewportStart: 0, viewportEnd: 180, in: plotRect)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: optimizedBitmap)
        PlaybackWaveformRenderer.drawPeaks(
            peaks,
            duration: 180,
            viewportStart: 0,
            viewportEnd: 180,
            in: plotRect
        )
        NSGraphicsContext.restoreGraphicsState()

        var differentPixels = 0
        var maximumChannelDifference = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * referenceBitmap.bytesPerRow + x * 4
                let difference = (0..<4).map {
                    abs(Int(referencePixels[offset + $0]) - Int(optimizedPixels[offset + $0]))
                }.max() ?? 0
                if difference > 0 {
                    differentPixels += 1
                    maximumChannelDifference = max(maximumChannelDifference, difference)
                }
            }
        }
        let maximumDifferentPixels = width * height / 100
        guard differentPixels <= maximumDifferentPixels, maximumChannelDifference <= 2 else {
            throw PerformanceBenchmarkError.unexpectedResult(
                "Batched waveform bars differed at \(differentPixels) pixels, max channel delta \(maximumChannelDifference)"
            )
        }
    }

    private static func drawReferenceWaveformPeaks(
        _ peaks: [Float],
        duration: TimeInterval,
        viewportStart: TimeInterval,
        viewportEnd: TimeInterval,
        in plotRect: NSRect
    ) {
        let startIndex = min(max(Int((viewportStart / duration * Double(peaks.count)).rounded(.down)), 0), peaks.count - 1)
        let endIndex = min(max(Int((viewportEnd / duration * Double(peaks.count)).rounded(.up)), startIndex + 1), peaks.count)
        let visiblePeaks = peaks[startIndex..<endIndex]
        let step = plotRect.width / CGFloat(visiblePeaks.count)
        let barWidth = max(1, step * 0.72)
        let centerY = plotRect.midY
        let maximumHeight = plotRect.height * 0.44
        AppTheme.accent.withAlphaComponent(0.78).setFill()
        for (index, peak) in visiblePeaks.enumerated() {
            let height = max(2, CGFloat(max(0, min(peak, 1))) * maximumHeight)
            let rect = NSRect(
                x: plotRect.minX + CGFloat(index) * step,
                y: centerY - height,
                width: barWidth,
                height: height * 2
            )
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    private static func makeWaveformBitmap(width: Int, height: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }

    static func equalizerApply() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "equalizer-apply",
            workload: PerformanceWorkload(
                description: "Apply 1,000 profiles with one changing band to AVAudioUnitEQ",
                operations: equalizerApplyCount,
                dimensions: ["profile_updates": equalizerApplyCount, "bands": EqualizerProfile.bandCount]
            ),
            prepare: {
                let player = AudioFilePlayer()
                var gains = Array(repeating: 0.0, count: EqualizerProfile.bandCount)
                let profiles = (0..<equalizerApplyCount).map { index in
                    let band = index % EqualizerProfile.bandCount
                    gains[band] = Double(index % 13 - 6)
                    return EqualizerProfile(isBypassed: false, bandGains: gains)
                }
                return PerformancePreparedIteration {
                    for profile in profiles {
                        player.apply(equalizerProfile: profile)
                    }
                }
            }
        )
    }


}