import Foundation
import GRDB
@testable import WavebookCore
import XCTest

extension LibraryRootTests {
    func testNestedRootsAreRejectedInEitherOrder() throws {
        let root = try makeRoot()
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let parentFirst = try LibraryDatabase(inMemory: true)
        _ = try parentFirst.addRoot(path: root.path)
        XCTAssertThrowsError(try parentFirst.addRoot(path: nested.path)) { error in
            guard case let .overlappingRoot(path, existingPath: existingPath) = error as? LibraryDatabaseError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, LibraryDatabase.canonicalRootPath(nested.path))
            XCTAssertEqual(existingPath, LibraryDatabase.canonicalRootPath(root.path))
        }

        let childFirst = try LibraryDatabase(inMemory: true)
        _ = try childFirst.addRoot(path: nested.path)
        XCTAssertThrowsError(try childFirst.addRoot(path: root.path)) { error in
            guard case let .overlappingRoot(path, existingPath: existingPath) = error as? LibraryDatabaseError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, LibraryDatabase.canonicalRootPath(root.path))
            XCTAssertEqual(existingPath, LibraryDatabase.canonicalRootPath(nested.path))
        }
    }
    func testSaveRejectsForeignAndEscapingDescendantSymlinkPaths() throws {
        let root = try makeRoot()
        let foreign = root.deletingLastPathComponent().appendingPathComponent("foreign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let descendantAlias = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: descendantAlias, withDestinationURL: foreign)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: descendantAlias)
            try? FileManager.default.removeItem(at: foreign)
        }

        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
         let track = Track(
             path: descendantAlias.appendingPathComponent("song.flac").path,
             title: "Song",
             artistDisplay: "Artist",
             albumTitle: "Album",
             genreDisplay: "",
             duration: 1,
             format: "flac"
         )

        XCTAssertThrowsError(try database.save(track: track, rootID: rootID)) { error in
            guard case let .pathOutsideRoot(path, rootPath: rootPath) = error as? LibraryDatabaseError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, LibraryDatabase.canonicalRootPath(foreign.appendingPathComponent("song.flac").path))
            XCTAssertEqual(rootPath, LibraryDatabase.canonicalRootPath(root.path))
        }
        XCTAssertThrowsError(try database.reconcile(rootPath: root.path, tracks: [track], lyricFiles: []))
         XCTAssertThrowsError(
             try database.reconcile(
                 rootPath: root.path,
                 tracks: [],
                 lyricFiles: [foreign.appendingPathComponent("song.lrc")]
             )
         )
    }
    func testRegisterLyricFileRejectsForeignCanonicalPath() throws {
        let root = try makeRoot()
         let foreign = root.deletingLastPathComponent().appendingPathComponent(
             "lyrics-foreign-\(UUID().uuidString)",
             isDirectory: true
         )
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Lyrics", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: foreign)
        }

        let database = try LibraryDatabase(inMemory: true)
        let rootID = try database.addRoot(path: root.path)
        let audioPath = root.appendingPathComponent("song.flac").path
         _ = try database.save(
             track: Track(
                 path: audioPath,
                 title: "Song",
                 artistDisplay: "Artist",
                 albumTitle: "Album",
                 genreDisplay: "",
                 duration: 1,
                 format: "flac"
             ),
             rootID: rootID
         )

        XCTAssertThrowsError(
            try database.registerLyricFile(alias.appendingPathComponent("song.lrc"), forTrackPath: audioPath)
        ) { error in
            guard case .pathOutsideRoot = error as? LibraryDatabaseError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCaseSensitiveVolumeKeepsCaseDistinctRoots() throws {
        let base = try makeRoot()
        let values = try base.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        try XCTSkipUnless(values.volumeSupportsCaseSensitiveNames == true, "Requires a case-sensitive test volume")

        let upper = base.appendingPathComponent("Music", isDirectory: true)
        let lower = base.appendingPathComponent("music", isDirectory: true)
        try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lower, withIntermediateDirectories: true)

        let databasePath = base.appendingPathComponent("Library.sqlite").path
        let upperID: Int64
        let lowerID: Int64
        do {
            let database = try LibraryDatabase(path: databasePath)
            upperID = try database.addRoot(path: upper.path)
            lowerID = try database.addRoot(path: lower.path)
        }

        let reopened = try LibraryDatabase(path: databasePath)
        XCTAssertNotEqual(upperID, lowerID)
        XCTAssertFalse(try LibraryDatabase.rootPathsOverlap(upper.path, lower.path))
        XCTAssertEqual(Set(try reopened.roots().map(\.path)), Set([upper.path, lower.path]))
    }
}
