import AppKit
import WavebookCore
import XCTest

@MainActor
final class OnboardingFoldersViewControllerTests: XCTestCase {
    func testExistingFoldersRemainManageableAndRemovalWaitsForConfirmation() throws {
        _ = NSApplication.shared
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wavebook-Onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let database = try LibraryDatabase(inMemory: true)
        _ = try database.addRoot(path: rootURL.path)
        let existingRoot = try XCTUnwrap(database.roots().first)
        var removalCount = 0
        let actions = LibraryFolderSettingsActions(
            roots: { (try? database.roots()) ?? [] },
            add: { _ in },
            remove: { _ in removalCount += 1 }
        )
        let controller = OnboardingFoldersViewController(
            folderActions: actions,
            scanSnapshot: LibraryScanSnapshot(isScanning: false, progress: nil, failure: nil),
            onBack: {},
            onContinue: {},
            onOpenLibrary: {}
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let table = try XCTUnwrap(appKitDescendants(of: NSTableView.self, in: controller.view).first)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(table.accessibilityLabel()?.contains("Library folders") ?? false)
        let addButton = try XCTUnwrap(appKitDescendants(of: NSButton.self, in: controller.view).first {
            $0.title == "Add Folder…"
        })
        XCTAssertEqual(addButton.accessibilityLabel(), "Add Library Folder")

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let removeButton = try XCTUnwrap(appKitDescendants(of: NSButton.self, in: controller.view).first {
            $0.title == "Remove Selected"
        })
        XCTAssertTrue(removeButton.isEnabled)
        sendAppKitAction(removeButton)

        XCTAssertEqual(removalCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingRoot.path))
        let sheet = try XCTUnwrap(window.attachedSheet)
        let alertText = appKitDescendants(of: NSTextField.self, in: try XCTUnwrap(sheet.contentView))
            .map(\.stringValue)
        XCTAssertTrue(alertText.contains { $0.contains(existingRoot.path) })
        XCTAssertTrue(alertText.contains { $0.contains("Files on disk will not be deleted.") })
    }

    func testScanStatusAndMatchedLyricsAreVisibleAndAccessible() throws {
        _ = NSApplication.shared
        let controller = OnboardingFoldersViewController(
            folderActions: LibraryFolderSettingsActions(roots: { [] }, add: { _ in }, remove: { _ in }),
            scanSnapshot: LibraryScanSnapshot(isScanning: false, progress: nil, failure: nil),
            onBack: {},
            onContinue: {},
            onOpenLibrary: {}
        )
        let status = try XCTUnwrap(appKitDescendants(of: NSTextField.self, in: controller.view).first {
            $0.stringValue.hasPrefix("Add one or more folders")
        })
        XCTAssertEqual(status.accessibilityLabel(), "Library scan status and matched lyric tracks")
        XCTAssertTrue(status.stringValue.contains("Matched lyric tracks: 0"))

        let musicURL = URL(fileURLWithPath: "/Music", isDirectory: true)
        controller.updateScanState(LibraryScanSnapshot(
            isScanning: true,
            progress: LibraryRootScanProgress(
                root: musicURL,
                completedFileCount: 2,
                totalFileCount: 5,
                matchedLyricTrackCount: nil
            ),
            failure: nil
        ))
        XCTAssertTrue(status.stringValue.contains("Music: Scanned 2 of 5 audio files."))
        XCTAssertTrue(status.stringValue.contains("Matching lyric tracks in Music…"))
        controller.updateScanState(LibraryScanSnapshot(
            isScanning: false,
            progress: LibraryRootScanProgress(
                root: musicURL,
                completedFileCount: 1,
                totalFileCount: 1,
                matchedLyricTrackCount: 1
            ),
            failure: nil
        ))
        XCTAssertTrue(status.stringValue.contains("Scanned 1 audio file in Music."))
        XCTAssertTrue(status.stringValue.contains("Tracks with matched lyrics in Music: 1"))

        controller.updateScanState(LibraryScanSnapshot(
            isScanning: false,
            progress: LibraryRootScanProgress(
                root: musicURL,
                completedFileCount: 0,
                totalFileCount: 0,
                matchedLyricTrackCount: 0
            ),
            failure: nil
        ))
        XCTAssertTrue(status.stringValue.contains("No supported audio files found in Music."))
        XCTAssertTrue(status.stringValue.contains("Tracks with matched lyrics in Music: 0"))

    }

    func testCompletedScanWithoutMatchedLyricsCountShowsUnavailable() throws {
        _ = NSApplication.shared
        let musicURL = URL(fileURLWithPath: "/Music", isDirectory: true)
        let controller = OnboardingFoldersViewController(
            folderActions: LibraryFolderSettingsActions(roots: { [] }, add: { _ in }, remove: { _ in }),
            scanSnapshot: LibraryScanSnapshot(isScanning: false, progress: nil, failure: nil),
            onBack: {},
            onContinue: {},
            onOpenLibrary: {}
        )
        controller.updateScanState(LibraryScanSnapshot(
            isScanning: false,
            progress: LibraryRootScanProgress(
                root: musicURL,
                completedFileCount: 0,
                totalFileCount: 0,
                matchedLyricTrackCount: nil
            ),
            failure: nil
        ))
        let status = try XCTUnwrap(appKitDescendants(of: NSTextField.self, in: controller.view).first {
            $0.accessibilityLabel() == "Library scan status and matched lyric tracks"
        })
        XCTAssertTrue(status.stringValue.contains("Tracks with matched lyrics in Music: unavailable"))
    }

    func testLastCompletedLyricsCountRemainsVisibleDuringNextScan() throws {
        _ = NSApplication.shared
        let controller = OnboardingFoldersViewController(
            folderActions: LibraryFolderSettingsActions(roots: { [] }, add: { _ in }, remove: { _ in }),
            scanSnapshot: LibraryScanSnapshot(isScanning: false, progress: nil, failure: nil),
            onBack: {},
            onContinue: {},
            onOpenLibrary: {}
        )
        controller.updateScanState(LibraryScanSnapshot(
            isScanning: true,
            progress: LibraryRootScanProgress(
                root: URL(fileURLWithPath: "/Music/Second", isDirectory: true),
                completedFileCount: 1,
                totalFileCount: 2,
                matchedLyricTrackCount: nil
            ),
            lastCompletedMatchedLyricsCount: LibraryRootMatchedLyricsCount(
                root: URL(fileURLWithPath: "/Music/First", isDirectory: true),
                matchedLyricTrackCount: 3
            ),
            failure: nil
        ))
        let labels = appKitDescendants(of: NSTextField.self, in: controller.view)
        let status = try XCTUnwrap(labels.first {
            $0.accessibilityLabel() == "Library scan status and matched lyric tracks"
        })
        XCTAssertTrue(status.stringValue.contains("Second: Scanned 1 of 2 audio files."))
        XCTAssertTrue(status.stringValue.contains("Tracks with matched lyrics in First: 3"))
    }

    func testMatchedLyricsCountUnavailableWhenFolderListCannotBeLoaded() throws {
        _ = NSApplication.shared
        let controller = OnboardingFoldersViewController(
            folderActions: LibraryFolderSettingsActions(roots: { nil }, add: { _ in }, remove: { _ in }),
            scanSnapshot: LibraryScanSnapshot(isScanning: false, progress: nil, failure: nil),
            onBack: {},
            onContinue: {},
            onOpenLibrary: {}
        )
        let status = try XCTUnwrap(appKitDescendants(of: NSTextField.self, in: controller.view).first {
            $0.accessibilityLabel() == "Library scan status and matched lyric tracks"
        })
        XCTAssertTrue(status.stringValue.contains("Matched lyric tracks: unavailable"))
    }

    func testScanFailureShowsMatchedLyricsUnavailable() throws {
        _ = NSApplication.shared
        let controller = OnboardingFoldersViewController(
            folderActions: LibraryFolderSettingsActions(roots: { [] }, add: { _ in }, remove: { _ in }),
            scanSnapshot: LibraryScanSnapshot(isScanning: false, progress: nil, failure: nil),
            onBack: {},
            onContinue: {},
            onOpenLibrary: {}
        )
        let status = try XCTUnwrap(appKitDescendants(of: NSTextField.self, in: controller.view).first {
            $0.accessibilityLabel() == "Library scan status and matched lyric tracks"
        })
        let musicURL = URL(fileURLWithPath: "/Music", isDirectory: true)
        controller.updateScanState(LibraryScanSnapshot(
            isScanning: false,
            progress: nil,
            failure: LibraryRootScanFailure(root: musicURL)
        ))
        XCTAssertTrue(status.stringValue.contains("Could not add or scan Music."))
        XCTAssertTrue(status.stringValue.contains("Any previously indexed music was kept."))
        XCTAssertTrue(status.stringValue.contains("Tracks with matched lyrics in Music: unavailable"))
    }

}
