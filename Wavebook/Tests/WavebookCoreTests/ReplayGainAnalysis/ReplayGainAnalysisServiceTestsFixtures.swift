import Foundation
@testable import WavebookCore
import XCTest

extension ReplayGainAnalysisServiceTests {
    var readyTrackValues: ReplayGainScopeValues {
        ReplayGainScopeValues(gain: ReplayGainGain(decibels: -4, source: .measured), samplePeak: 0.5)
    }

    var readyAlbumValues: ReplayGainScopeValues {
        ReplayGainScopeValues(gain: ReplayGainGain(decibels: -3, source: .measured), samplePeak: 0.75)
    }

    func makeDatabase(root: URL, urls: [URL]) throws -> LibraryDatabase {
        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        for url in urls {
            _ = try database.save(
                track: Track(
                    path: url.path,
                    title: url.deletingPathExtension().lastPathComponent,
                    artistDisplay: "Artist",
                    albumTitle: "Album",
                    albumArtist: "Artist",
                    genreDisplay: "",
                    duration: 1,
                    format: url.pathExtension
                ),
                rootID: rootID
            )
        }
        return database
    }

    func makeCommittingService(
        database: LibraryDatabase,
        trackValues: ReplayGainScopeValues,
        albumValues: ReplayGainScopeValues
    ) -> ReplayGainAnalysisService {
        ReplayGainAnalysisService(
            database: database,
            analyzeTrack: { item, database in
                _ = try database.commitReplayGainTrackResult(
                    trackID: item.trackID,
                    fingerprint: item.fingerprint,
                    claimToken: item.claimToken,
                    values: trackValues
                )
                return .committed(trackID: item.trackID, values: trackValues)
            },
            analyzeAlbum: { _, _ in albumValues }
        )
    }

    func makeAudioFile(in root: URL, name: String) throws -> URL {
        let url = root.appending(path: name)
        try Data([0]).write(to: url)
        return url
    }

    func fixtureURL(fileExtension: String) throws -> URL {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: ReplayGainAnalysisServiceTests.self)
        #endif
        return try XCTUnwrap(
            bundle.url(forResource: "replaygain-gate", withExtension: fileExtension, subdirectory: "Fixtures")
                ?? bundle.url(forResource: "replaygain-gate", withExtension: fileExtension)
        )
    }

    func makeRoot() throws -> URL {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".test-tmp")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func waitUntil(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("Timed out waiting for analysis state")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
