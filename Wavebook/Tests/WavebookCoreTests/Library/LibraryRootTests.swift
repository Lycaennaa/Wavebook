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
    func testSecurityScopedBookmarkPersistsAndUpdatesForExistingRoot() throws {
        let root = try makeRoot()
        let databaseDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-tmp", isDirectory: true)
            .appendingPathComponent("root-bookmark-\(UUID().uuidString)", isDirectory: true)
        let databasePath = databaseDirectory.appendingPathComponent("library.sqlite")
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseDirectory) }
        let database = try LibraryDatabase(path: databasePath.path)
        let firstBookmark = Data([1, 2])
        let rootID = try database.addRoot(path: root.path, securityScopedBookmark: firstBookmark)

        let registeredRoot = try XCTUnwrap(try database.roots().first)
        XCTAssertEqual(registeredRoot.securityScopedBookmark, firstBookmark)

        let updatedBookmark = Data([3, 4])
        XCTAssertEqual(
            try database.addRoot(path: root.path, securityScopedBookmark: updatedBookmark),
            rootID
        )
        _ = try database.addRoot(path: root.path)
        XCTAssertEqual(try XCTUnwrap(try database.roots().first).securityScopedBookmark, updatedBookmark)
        let reopenedDatabase = try LibraryDatabase(path: databasePath.path)
        XCTAssertEqual(
            try XCTUnwrap(try reopenedDatabase.roots().first).securityScopedBookmark,
            updatedBookmark
        )
        XCTAssertTrue(try reopenedDatabase.removeRoot(id: rootID))
        XCTAssertTrue(try reopenedDatabase.roots().isEmpty)
    }
    func testUpdateRootPathPreservesRootIDAndBookmark() throws {
        let base = try makeRoot()
        let originalRoot = base.appendingPathComponent("original", isDirectory: true)
        let movedRoot = base.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: originalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: movedRoot, withIntermediateDirectories: true)
        let database = try LibraryDatabase(inMemory: true)
        let bookmark = Data([7, 8])
        let rootID = try database.addRoot(path: originalRoot.path, securityScopedBookmark: bookmark)

        let updatedPath = try database.updateRootPath(movedRoot.path, forRootID: rootID)
        let storedRoot = try XCTUnwrap(try database.roots().first)

        XCTAssertEqual(updatedPath, movedRoot.path)
        XCTAssertEqual(storedRoot.id, rootID)
        XCTAssertEqual(storedRoot.path, movedRoot.path)
        XCTAssertEqual(storedRoot.securityScopedBookmark, bookmark)
    }

    func testUpdateRootPathRejectsAnotherRootWithoutReplacingIt() throws {
        let base = try makeRoot()
        let originalRoot = base.appendingPathComponent("original", isDirectory: true)
        let existingRoot = base.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: originalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: existingRoot, withIntermediateDirectories: true)
        let database = try LibraryDatabase(inMemory: true)
        let movingRootID = try database.addRoot(path: originalRoot.path)
        let existingRootID = try database.addRoot(path: existingRoot.path)

        XCTAssertThrowsError(try database.updateRootPath(existingRoot.path, forRootID: movingRootID))

        let roots = try database.roots()
        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(roots.first(where: { $0.id == movingRootID })?.path, originalRoot.path)
        XCTAssertEqual(roots.first(where: { $0.id == existingRootID })?.path, existingRoot.path)
    }
    func testRootsKeepStoredCanonicalPathAfterFilesystemSymlinkChanges() throws {
        let base = try makeRoot()
        let selectedRoot = base.appendingPathComponent("selected", isDirectory: true)
        let replacementRoot = base.appendingPathComponent("replacement", isDirectory: true)
        let movedRoot = base.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)
        let database = try LibraryDatabase(inMemory: true)
        _ = try database.addRoot(path: selectedRoot.path)

        try FileManager.default.moveItem(at: selectedRoot, to: movedRoot)
        try FileManager.default.createSymbolicLink(at: selectedRoot, withDestinationURL: replacementRoot)

        XCTAssertEqual(try database.roots().map(\.path), [selectedRoot.path])
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
