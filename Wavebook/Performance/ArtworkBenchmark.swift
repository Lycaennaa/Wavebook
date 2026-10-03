import CoreGraphics
import Foundation
import ImageIO
import WavebookCore

enum ArtworkBenchmark {
    private static let artworkDimension = 2_048
    private static let fileCount = 32

    static func embeddedRead() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "artwork-embedded",
            workload: PerformanceWorkload(
                description: "Embedded FLAC picture extraction from synthetic files",
                operations: fileCount,
                dimensions: ["files": fileCount, "image_dimension_px": artworkDimension]
            ),
            prepare: {
                let directory = try PerformanceFixtures.temporaryDirectory(named: "artwork-embedded")
                let image = try makePNG()
                let audioData = makeFLACArtworkFile(image)
                var files: [URL] = []
                for index in 0..<fileCount {
                    let url = directory.appending(path: "Track-\(index).flac")
                    try audioData.write(to: url)
                    files.append(url)
                }
                let reader = AudioArtworkReader()
                return PerformancePreparedIteration(operation: {
                    for url in files {
                        guard let data = await reader.artworkData(for: url), data.count == image.count else {
                            throw PerformanceBenchmarkError.unexpectedResult("Embedded artwork was not extracted")
                        }
                    }
                }, cleanup: {
                    try? FileManager.default.removeItem(at: directory)
                })
            }
        )
    }

    static func sidecarRead() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "artwork-sidecar",
            workload: PerformanceWorkload(
                description: "Sidecar read after synthetic WAV embedded-art miss",
                operations: fileCount,
                dimensions: [
                    "audio_files": fileCount,
                    "image_dimension_px": artworkDimension,
                    "sample_rate_hz": 8_000
                ]
            ),
            prepare: {
                let directory = try PerformanceFixtures.temporaryDirectory(named: "artwork-sidecar")
                let image = try makePNG()
                try image.write(to: directory.appending(path: "cover.png"))
                let audioData = PerformanceFixtures.makeWaveFile()
                var files: [URL] = []
                for index in 0..<fileCount {
                    let url = directory.appending(path: "Track-\(index).wav")
                    try audioData.write(to: url)
                    files.append(url)
                }
                let reader = AudioArtworkReader()
                return PerformancePreparedIteration(operation: {
                    for url in files {
                        guard let data = await reader.artworkData(for: url), data.count == image.count else {
                            throw PerformanceBenchmarkError.unexpectedResult("Sidecar artwork was not loaded")
                        }
                    }
                }, cleanup: {
                    try? FileManager.default.removeItem(at: directory)
                })
            }
        )
    }

    static func cacheFingerprint() async throws -> PerformanceRun {
        try await PerformanceBenchmark.run(
            scenario: "artwork-cache-fingerprint",
            workload: PerformanceWorkload(
                description: "Artwork cache fingerprint after synthetic WAV embedded-art miss",
                operations: fileCount,
                dimensions: [
                    "audio_files": fileCount,
                    "image_dimension_px": artworkDimension,
                    "sample_rate_hz": 8_000
                ]
            ),
            prepare: {
                let directory = try PerformanceFixtures.temporaryDirectory(named: "artwork-fingerprint")
                let image = try makePNG()
                try image.write(to: directory.appending(path: "cover.png"))
                let audioData = PerformanceFixtures.makeWaveFile()
                var files: [URL] = []
                for index in 0..<fileCount {
                    let url = directory.appending(path: "Track-\(index).wav")
                    try audioData.write(to: url)
                    files.append(url)
                }
                let reader = AudioArtworkReader()
                return PerformancePreparedIteration(operation: {
                    for url in files {
                        guard !reader.artworkCacheFingerprint(for: url).isEmpty else {
                            throw PerformanceBenchmarkError.unexpectedResult("Artwork fingerprint was empty")
                        }
                    }
                }, cleanup: {
                    try? FileManager.default.removeItem(at: directory)
                })
            }
        )
    }

    static func decode() async throws -> PerformanceRun {
        let decodeCount = 20
        return try await PerformanceBenchmark.run(
            scenario: "artwork-decode",
            workload: PerformanceWorkload(
                description: "ImageIO thumbnail decode and rasterization",
                operations: decodeCount,
                dimensions: [
                    "source_dimension_px": artworkDimension,
                    "thumbnail_max_px": 256,
                    "rasterized_pixels": 65_536
                ]
            ),
            prepare: {
                let imageData = try makePNG()
                return PerformancePreparedIteration {
                    for _ in 0..<decodeCount {
                        guard let image = AudioArtworkReader.decodedArtworkImage(imageData, maximumPixelSize: 256),
                              image.width <= 256,
                              image.height <= 256,
                              let context = CGContext(
                                data: nil,
                                width: 256,
                                height: 256,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                              ) else {
                            throw PerformanceBenchmarkError.unexpectedResult("Artwork thumbnail decode failed")
                        }
                        context.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 256))
                    }
                }
            }
        )
    }

    private static func makePNG() throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: artworkDimension,
            height: artworkDimension,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PerformanceBenchmarkError.unexpectedResult("Could not create artwork image fixture")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: artworkDimension, height: artworkDimension))
        guard let image = context.makeImage() else {
            throw PerformanceBenchmarkError.unexpectedResult("Could not render artwork image fixture")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw PerformanceBenchmarkError.unexpectedResult("Could not encode artwork image fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PerformanceBenchmarkError.unexpectedResult("Could not finalize artwork image fixture")
        }
        return output as Data
    }

    private static func makeFLACArtworkFile(_ image: Data) -> Data {
        let mime = Data("image/png".utf8)
        var picture = Data()
        PerformanceFixtures.appendBigEndian(UInt32(3), to: &picture)
        PerformanceFixtures.appendBigEndian(UInt32(mime.count), to: &picture)
        picture.append(mime)
        PerformanceFixtures.appendBigEndian(UInt32(0), to: &picture)
        PerformanceFixtures.appendBigEndian(UInt32(artworkDimension), to: &picture)
        PerformanceFixtures.appendBigEndian(UInt32(artworkDimension), to: &picture)
        PerformanceFixtures.appendBigEndian(UInt32(32), to: &picture)
        PerformanceFixtures.appendBigEndian(UInt32(0), to: &picture)
        PerformanceFixtures.appendBigEndian(UInt32(image.count), to: &picture)
        picture.append(image)

        var file = Data("fLaC".utf8)
        file.append(0x86)
        file.append(UInt8(truncatingIfNeeded: picture.count >> 16))
        file.append(UInt8(truncatingIfNeeded: picture.count >> 8))
        file.append(UInt8(truncatingIfNeeded: picture.count))
        file.append(picture)
        return file
    }
}