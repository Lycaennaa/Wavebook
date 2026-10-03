import Foundation

struct BoundedFileReader {
    let handle: FileHandle
    let limit: UInt64
    private(set) var offset: UInt64 = 0

    init(handle: FileHandle, fileSize: UInt64, limit: UInt64) {
        self.handle = handle
        self.limit = min(fileSize, limit)
    }

    mutating func read(count: Int) -> Data? {
        guard count >= 0,
              offset <= limit,
              let requestedCount = UInt64(exactly: count),
              requestedCount <= limit - offset else { return nil }
        if requestedCount == 0 { return Data() }
        guard let data = try? handle.read(upToCount: count), UInt64(data.count) == requestedCount else { return nil }
        offset += requestedCount
        return data
    }
    mutating func read(count: Int, budget: inout AudioMetadataBudget) throws -> Data? {
        guard let requestedCount = UInt64(exactly: count) else { return nil }
        try budget.addProbe(bytes: requestedCount)
        return read(count: count)
    }

    mutating func skip(_ count: UInt64) -> Bool {
        guard offset <= limit, count <= limit - offset else { return false }
        do {
            try handle.seek(toOffset: offset + count)
        } catch {
            return false
        }
        offset += count
        return true
    }

    mutating func seek(to target: UInt64) -> Bool {
        guard target <= limit else { return false }
        do {
            try handle.seek(toOffset: target)
        } catch {
            return false
        }
        offset = target
        return true
    }

    mutating func finishPaddedChunk(chunkEnd: UInt64, containerEnd: UInt64, chunkSize: UInt64) -> Bool {
        guard seek(to: chunkEnd) else { return false }
        guard chunkSize & 1 == 0 else {
            guard chunkEnd < containerEnd, skip(1) else { return false }
            return true
        }
        return true
    }
}
