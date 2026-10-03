import Darwin
import Foundation

struct ProcessResourceSnapshot: Sendable {
    let cpuTimeNanoseconds: UInt64
    let peakResidentBytes: UInt64
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let diskBytesRead: UInt64
    let diskBytesWritten: UInt64
    let logicalWrites: UInt64?
    let pageIns: UInt64
    let energyNanojoules: UInt64?
}

enum ProcessMetrics {
    private struct ExtendedUsage {
        let residentBytes: UInt64
        let physicalFootprintBytes: UInt64
        let diskBytesRead: UInt64
        let diskBytesWritten: UInt64
        let logicalWrites: UInt64?
        let pageIns: UInt64
        let energyNanojoules: UInt64?

        nonisolated init(
            residentBytes: UInt64,
            physicalFootprintBytes: UInt64,
            diskBytesRead: UInt64,
            diskBytesWritten: UInt64,
            logicalWrites: UInt64?,
            pageIns: UInt64,
            energyNanojoules: UInt64?
        ) {
            self.residentBytes = residentBytes
            self.physicalFootprintBytes = physicalFootprintBytes
            self.diskBytesRead = diskBytesRead
            self.diskBytesWritten = diskBytesWritten
            self.logicalWrites = logicalWrites
            self.pageIns = pageIns
            self.energyNanojoules = energyNanojoules
        }
    }

    static func snapshot() throws -> ProcessResourceSnapshot {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let extended = try extendedUsage()

        return ProcessResourceSnapshot(
            cpuTimeNanoseconds: nanoseconds(usage.ru_utime) + nanoseconds(usage.ru_stime),
            peakResidentBytes: UInt64(max(0, usage.ru_maxrss)),
            residentBytes: extended.residentBytes,
            physicalFootprintBytes: extended.physicalFootprintBytes,
            diskBytesRead: extended.diskBytesRead,
            diskBytesWritten: extended.diskBytesWritten,
            logicalWrites: extended.logicalWrites,
            pageIns: extended.pageIns,
            energyNanojoules: extended.energyNanojoules
        )
    }

    nonisolated static func memorySnapshot() throws -> ProcessMemorySnapshot {
        let usage = try extendedUsage()
        return ProcessMemorySnapshot(
            residentBytes: usage.residentBytes,
            physicalFootprintBytes: usage.physicalFootprintBytes
        )
    }
    private nonisolated static func extendedUsage() throws -> ExtendedUsage {
        var usage = rusage_info_v6()
        let versionSixResult = withUnsafeMutablePointer(to: &usage) { pointer in
            proc_pid_rusage(
                getpid(),
                RUSAGE_INFO_V6,
                UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            )
        }
        if versionSixResult == 0 {
            return ExtendedUsage(
                residentBytes: usage.ri_resident_size,
                physicalFootprintBytes: usage.ri_phys_footprint,
                diskBytesRead: usage.ri_diskio_bytesread,
                diskBytesWritten: usage.ri_diskio_byteswritten,
                logicalWrites: usage.ri_logical_writes,
                pageIns: usage.ri_pageins,
                energyNanojoules: usage.ri_energy_nj
            )
        }

        var compatibleUsage = rusage_info_v2()
        let versionTwoResult = withUnsafeMutablePointer(to: &compatibleUsage) { pointer in
            proc_pid_rusage(
                getpid(),
                RUSAGE_INFO_V2,
                UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            )
        }
        guard versionTwoResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return ExtendedUsage(
            residentBytes: compatibleUsage.ri_resident_size,
            physicalFootprintBytes: compatibleUsage.ri_phys_footprint,
            diskBytesRead: compatibleUsage.ri_diskio_bytesread,
            diskBytesWritten: compatibleUsage.ri_diskio_byteswritten,
            logicalWrites: nil,
            pageIns: compatibleUsage.ri_pageins,
            energyNanojoules: nil
        )
    }

    private static func nanoseconds(_ value: timeval) -> UInt64 {
        UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_usec) * 1_000
    }
}

struct ProcessMemorySnapshot: Sendable {
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64

    nonisolated init(residentBytes: UInt64, physicalFootprintBytes: UInt64) {
        self.residentBytes = residentBytes
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

struct ProcessMemoryPeak: Sendable {
    let residentGrowthBytes: UInt64
    let physicalFootprintGrowthBytes: UInt64
}

final class ProcessMemorySampler: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated private let queue: DispatchQueue
    nonisolated private let timer: DispatchSourceTimer
    nonisolated(unsafe) private var baseline: ProcessMemorySnapshot?
    nonisolated(unsafe) private var peakResidentBytes: UInt64 = 0
    nonisolated(unsafe) private var peakPhysicalFootprintBytes: UInt64 = 0
    nonisolated(unsafe) private var samplingFailed = false

    nonisolated init() {
        let queue = DispatchQueue(label: "WavebookPerformance.memory-sampler")
        self.queue = queue
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.schedule(deadline: .distantFuture, repeating: .seconds(1))
        timer.resume()
        queue.sync {}
    }

    func start(baseline: ProcessMemorySnapshot) {
        lock.lock()
        self.baseline = baseline
        peakResidentBytes = baseline.residentBytes
        peakPhysicalFootprintBytes = baseline.physicalFootprintBytes
        lock.unlock()
        timer.schedule(
            deadline: .now() + .milliseconds(10),
            repeating: .milliseconds(10),
            leeway: .milliseconds(2)
        )
    }

    func finish(after snapshot: ProcessMemorySnapshot) throws -> ProcessMemoryPeak {
        timer.cancel()
        queue.sync {}
        lock.lock()
        defer { lock.unlock() }
        guard let baseline, !samplingFailed else {
            throw PerformanceBenchmarkError.invalidResourceMeasurement
        }
        peakResidentBytes = max(peakResidentBytes, snapshot.residentBytes)
        peakPhysicalFootprintBytes = max(peakPhysicalFootprintBytes, snapshot.physicalFootprintBytes)
        return ProcessMemoryPeak(
            residentGrowthBytes: peakResidentBytes > baseline.residentBytes
                ? peakResidentBytes - baseline.residentBytes : 0,
            physicalFootprintGrowthBytes: peakPhysicalFootprintBytes > baseline.physicalFootprintBytes
                ? peakPhysicalFootprintBytes - baseline.physicalFootprintBytes : 0
        )
    }

    func cancel() {
        timer.cancel()
        queue.sync {}
    }

    private nonisolated func sample() {
        do {
            let snapshot = try ProcessMetrics.memorySnapshot()
            lock.lock()
            defer { lock.unlock() }
            guard baseline != nil else { return }
            peakResidentBytes = max(peakResidentBytes, snapshot.residentBytes)
            peakPhysicalFootprintBytes = max(peakPhysicalFootprintBytes, snapshot.physicalFootprintBytes)
        } catch {
            lock.lock()
            samplingFailed = true
            lock.unlock()
        }
    }
}