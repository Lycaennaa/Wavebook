import Foundation
@testable import WavebookCore

final class AnalysisConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var calls = 0
    private var maximum = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    var maximumActiveCount: Int {
        lock.withLock { maximum }
    }

    func enter() {
        lock.withLock {
            activeCount += 1
            calls += 1
            maximum = max(maximum, activeCount)
        }
    }

    func leave() {
        lock.withLock { activeCount -= 1 }
    }
}

final class PathProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    var value: [String] {
        lock.withLock { paths }
    }

    func set(_ paths: [String]) {
        lock.withLock { self.paths = paths }
    }
}

final class AnalysisOrderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var value: [String] {
        lock.withLock { events }
    }

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }
}
final class FileChangeDuringAlbumProbe: @unchecked Sendable {
    private let changedURL: URL
    private let values: ReplayGainScopeValues
    private let lock = NSLock()
    private var attempts = 0

    init(url: URL, values: ReplayGainScopeValues) {
        changedURL = url
        self.values = values
    }

    var callCount: Int {
        lock.withLock { attempts }
    }

    func analyze(_ item: ReplayGainAlbumAnalysisItem) throws -> ReplayGainScopeValues {
        let shouldChange = lock.withLock {
            attempts += 1
            return attempts == 1
        }
        if shouldChange {
            try Data([1, 2]).write(to: changedURL)
        }
        return values
    }
}

final class FailingAlbumProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let successValues: ReplayGainScopeValues
    private var attempts = 0
    private var paths: [String] = []

    init(successValues: ReplayGainScopeValues) {
        self.successValues = successValues
    }

    var successfulPaths: [String] {
        lock.withLock { paths }
    }

    func analyze(_ item: ReplayGainAlbumAnalysisItem) throws -> ReplayGainScopeValues {
        try lock.withLock {
            attempts += 1
            if attempts == 1 {
                throw ReplayGainAnalyzerError.conflictingAlbumGainValues
            }
            paths = item.availablePaths
            return successValues
        }
    }
}

enum TestServiceError: Error, LocalizedError {
    case failed

    var errorDescription: String? { "service failed" }
}
