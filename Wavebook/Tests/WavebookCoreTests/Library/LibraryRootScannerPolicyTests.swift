import Foundation
@testable import WavebookCore
import XCTest

extension LibraryRootTests {
    func test65LinkEscapeChainIsRejectedByRootBoundaries() async throws {
        let root = try makeRoot()
        let outside = root.deletingLastPathComponent().appendingPathComponent(
            "outside-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }

        let lastIndex = LibraryDatabase.rootSymlinkResolutionLimit
        let links = (0...lastIndex).map { index in
            root.appendingPathComponent(index == 0 ? "Escape.wav" : "escape-\(index)", isDirectory: true)
        }
        for index in links.indices {
            let destination = index == links.index(before: links.endIndex) ? outside : links[links.index(after: index)]
            try FileManager.default.createSymbolicLink(at: links[index], withDestinationURL: destination)
        }

        let candidatePath = links[0].appendingPathComponent("song.flac").path
        let expectedError = RootPathResolutionError.symlinkResolutionLimitExceeded(
            path: URL(fileURLWithPath: candidatePath).absoluteURL.path,
            limit: lastIndex
        )
        XCTAssertThrowsError(try LibraryDatabase.resolveRootPath(candidatePath)) { error in
            XCTAssertEqual(error as? RootPathResolutionError, expectedError)
        }

        let database = try LibraryDatabase(inMemory: true)
        let selectedRoot = links[0].standardizedFileURL
        let expectedRootError = RootPathResolutionError.symlinkResolutionLimitExceeded(
            path: selectedRoot.absoluteURL.path,
            limit: lastIndex
        )
        XCTAssertThrowsError(try database.addRoot(path: selectedRoot.path)) { error in
            XCTAssertEqual(error as? RootPathResolutionError, expectedRootError)
        }
        do {
            _ = try await LibraryScanner().scan(root: selectedRoot, database: database)
            XCTFail("Expected selected root resolution failure")
        } catch {
            XCTAssertEqual(error as? RootPathResolutionError, expectedRootError)
        }

        XCTAssertThrowsError(try database.addRoot(path: candidatePath)) { error in
            XCTAssertEqual(error as? RootPathResolutionError, expectedError)
        }
        let rootID = try database.addRoot(path: root.path)
        let track = Track(
            path: candidatePath,
            title: "Song",
            artistDisplay: "Artist",
            albumTitle: "Album",
            genreDisplay: "",
            duration: 1,
            format: "flac"
        )
        XCTAssertThrowsError(try database.save(track: track, rootID: rootID)) { error in
            XCTAssertEqual(error as? RootPathResolutionError, expectedError)
        }
        XCTAssertThrowsError(try database.reconcile(rootPath: root.path, tracks: [track], lyricFiles: [])) { error in
            XCTAssertEqual(error as? RootPathResolutionError, expectedError)
        }
        let scanResult = try await LibraryScanner().scan(root: root, database: database)
        XCTAssertTrue(scanResult.tracks.isEmpty)
        XCTAssertTrue(try database.tracks().isEmpty)

    }

    func testSymlinkLoopIsRejectedByRootBoundaries() async throws {
        let root = try makeRoot()
        let first = root.appendingPathComponent("Loop.wav", isDirectory: true)
        let second = root.appendingPathComponent("loop-target", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: second)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)

        let candidatePath = first.appendingPathComponent("song.flac").path
        let expectedError = RootPathResolutionError.symlinkLoop(
            path: URL(fileURLWithPath: candidatePath).absoluteURL.path
        )
        XCTAssertThrowsError(try LibraryDatabase.resolveRootPath(candidatePath)) { error in
            XCTAssertEqual(error as? RootPathResolutionError, expectedError)
        }

        let database = try LibraryDatabase(inMemory: true)
        let selectedRoot = first.standardizedFileURL
        let expectedRootError = RootPathResolutionError.symlinkLoop(
            path: selectedRoot.absoluteURL.path
        )
        XCTAssertThrowsError(try database.addRoot(path: selectedRoot.path)) { error in
            XCTAssertEqual(error as? RootPathResolutionError, expectedRootError)
        }
        do {
            _ = try await LibraryScanner().scan(root: selectedRoot, database: database)
            XCTFail("Expected selected root resolution failure")
        } catch {
            XCTAssertEqual(error as? RootPathResolutionError, expectedRootError)
        }

        XCTAssertThrowsError(try database.addRoot(path: candidatePath)) { error in
            XCTAssertEqual(error as? RootPathResolutionError, expectedError)
        }
        let rootID = try database.addRoot(path: root.path)
        let track = Track(
            path: candidatePath,
            title: "Song",
            artistDisplay: "Artist",
            albumTitle: "Album",
            genreDisplay: "",
            duration: 1,
            format: "flac"
        )
        XCTAssertThrowsError(try database.save(track: track, rootID: rootID)) { error in
            XCTAssertEqual(error as? RootPathResolutionError, expectedError)
        }
        XCTAssertThrowsError(try database.reconcile(rootPath: root.path, tracks: [track], lyricFiles: [])) { error in
            XCTAssertEqual(error as? RootPathResolutionError, expectedError)
        }
        let scanResult = try await LibraryScanner().scan(root: root, database: database)
        XCTAssertTrue(scanResult.tracks.isEmpty)
        XCTAssertTrue(try database.tracks().isEmpty)

    }

}
