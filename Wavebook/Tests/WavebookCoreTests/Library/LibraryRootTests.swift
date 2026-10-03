import Foundation
import GRDB
@testable import WavebookCore
import XCTest

extension LibraryRootTests {
    func testSymlinkAndEquivalentPathsShareCanonicalRoot() throws {
        let root = try makeRoot()
        let symlink = root.deletingLastPathComponent().appendingPathComponent("alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: symlink) }

        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let symlinkID = try database.addRoot(path: symlink.path)
        let lexicalID = try database.addRoot(path: root.path + "/./")

        XCTAssertEqual(rootID, symlinkID)
        XCTAssertEqual(rootID, lexicalID)
        XCTAssertEqual(try database.roots().map(\.path), [LibraryDatabase.canonicalRootPath(root.path)])
    }
    func testRootsUseRawPathTieBreak() throws {
        let database = try LibraryDatabase(inMemory: true)
        let base = "/root-order-stable-"
        let uppercase = base + "A"
        let lowercase = base + "a"
         try database.writer.write { database in
             try database.execute(
                 sql: "INSERT INTO roots (id, path, lastScanAt) VALUES (?, ?, NULL)",
                 arguments: [1, lowercase]
             )
             try database.execute(
                 sql: "INSERT INTO roots (id, path, lastScanAt) VALUES (?, ?, NULL)",
                 arguments: [2, uppercase]
             )
         }

        XCTAssertEqual(try database.roots().map(\.path), [uppercase, lowercase])
    }

    func testSymlinkCanonicalizationKeepsMissingPathsSafe() throws {
        let base = try makeRoot()
        let target = base.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let symlink = base.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        addTeardownBlock { try? FileManager.default.removeItem(at: symlink) }

        let missingPath = symlink.path + "/missing/child"
        let expectedPath = target.path + "/missing/child"

        XCTAssertEqual(
            LibraryDatabase.canonicalRootPath(missingPath),
            LibraryDatabase.canonicalRootPath(expectedPath)
        )
        let parentTraversalPath = symlink.path + "/missing/../child"
        XCTAssertEqual(
            try LibraryDatabase.resolveRootPath(parentTraversalPath),
            target.appendingPathComponent("child").path
        )

        let database = try LibraryDatabase(inMemory: true)
        _ = try database.addRoot(path: missingPath)
        XCTAssertEqual(try database.roots().map(\.path), [LibraryDatabase.canonicalRootPath(expectedPath)])
    }
    func testRepeatedSymlinkTraversalDoesNotLookLikeALoop() throws {
        let root = try makeRoot()
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        addTeardownBlock { try? FileManager.default.removeItem(at: alias) }

        let path = alias.path + "/../Alias/song.flac"
        XCTAssertEqual(
            try LibraryDatabase.resolveRootPath(path),
            target.appendingPathComponent("song.flac").path
        )
    }

    func testUnexpectedSymlinkLookupFailureIsTyped() throws {
        let path = "/root-resolution-test/failure/song.flac"
        let failingComponent = "/root-resolution-test/failure"
        let failure = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadUnknown.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "Injected permission failure",
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(POSIXErrorCode.EACCES.rawValue)
                )
            ]
        )

        XCTAssertThrowsError(
            try LibraryDatabase.resolveRootPath(path) { candidate in
                if candidate == failingComponent { throw failure }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EINVAL.rawValue))
            }
        ) { error in
            guard let resolutionError = error as? RootPathResolutionError else {
                return XCTFail("Unexpected error: \(error)")
            }
            guard case let .symlinkResolutionFailed(
                path: actualPath,
                componentPath: actualComponentPath,
                reason: reason
            ) = resolutionError else {
                return XCTFail("Unexpected error: \(resolutionError)")
            }
            XCTAssertEqual(actualPath, path)
            XCTAssertEqual(actualComponentPath, failingComponent)
            XCTAssertTrue(reason.contains("Injected permission failure"))
        }
    }
}
