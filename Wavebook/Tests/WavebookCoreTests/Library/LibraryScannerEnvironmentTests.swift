import Foundation
@testable import WavebookCore
import XCTest

extension LibraryScannerTests {
    func testInMemoryInitializerRejectsFalse() {
        XCTAssertThrowsError(try LibraryDatabase(inMemory: false))
    }

    func testAppSandboxMatchesPlainPathPersistencePlan() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectCandidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "Wavebook.xcodeproj/project.pbxproj"),
            sourceDirectory
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Wavebook.xcodeproj/project.pbxproj")
        ]
         guard let project = projectCandidates.first(where: {
             FileManager.default.isReadableFile(atPath: $0.path)
         }) else {
            throw XCTSkip("Xcode project is unavailable in this test environment")
        }
        let settings = try String(contentsOf: project, encoding: .utf8)
        XCTAssertFalse(settings.contains("ENABLE_APP_SANDBOX = YES"))
        XCTAssertTrue(settings.contains("ENABLE_APP_SANDBOX = NO"))
    }

}
