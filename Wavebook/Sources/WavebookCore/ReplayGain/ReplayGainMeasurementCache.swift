import Foundation

actor ReplayGainMeasurementCache {
    private struct Key: Hashable {
        let path: String
        let fingerprint: ReplayGainFileFingerprint
    }

    private static let maximumEntryCount = 512
    private var measurements: [Key: ReplayGainAlbumDecoder.DecodedMeasurement] = [:]
    private var accessOrder: [Key] = []

    func store(
        _ measurement: ReplayGainAlbumDecoder.DecodedMeasurement,
        for path: String,
        fingerprint: ReplayGainFileFingerprint
    ) {
        let key = Self.key(for: path, fingerprint: fingerprint)
        measurements[key] = measurement
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        while accessOrder.count > Self.maximumEntryCount {
            let evicted = accessOrder.removeFirst()
            measurements.removeValue(forKey: evicted)
        }
    }

    func values(
        for paths: [String],
        fingerprints: [String: ReplayGainFileFingerprint]
    ) -> [ReplayGainAnalyzer.ReplayGainCachedMeasurement] {
        var result: [ReplayGainAnalyzer.ReplayGainCachedMeasurement] = []
        for path in paths {
            let normalizedPath = Self.normalizedPath(path)
            guard let fingerprint = fingerprints[path] ?? fingerprints[normalizedPath] else { continue }
            let key = Key(path: normalizedPath, fingerprint: fingerprint)
            guard let measurement = measurements[key] else { continue }
            result.append(ReplayGainAnalyzer.ReplayGainCachedMeasurement(
                path: normalizedPath,
                fingerprint: fingerprint,
                measurement: measurement
            ))
            accessOrder.removeAll { $0 == key }
            accessOrder.append(key)
        }
        return result
    }

    func removeAll() {
        measurements.removeAll(keepingCapacity: true)
        accessOrder.removeAll(keepingCapacity: true)
    }

    func remove(paths: [String]) {
        let normalizedPaths = Set(paths.map(Self.normalizedPath))
        measurements = measurements.filter { !normalizedPaths.contains($0.key.path) }
        accessOrder.removeAll { normalizedPaths.contains($0.path) }
    }

    private static func key(for path: String, fingerprint: ReplayGainFileFingerprint) -> Key {
        Key(path: normalizedPath(path), fingerprint: fingerprint)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
