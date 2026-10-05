import AppKit
import XCTest

@MainActor
final class RootSplitViewTests: XCTestCase {
    func testPanesStayAdjacentAcrossRepeatedWindowResizes() {
        assertPaneLayout(for: [
            NSSize(width: 1_180, height: 760),
            NSSize(width: 1_800, height: 1_000),
            NSSize(width: 960, height: 600),
            NSSize(width: 1_400, height: 850),
            NSSize(width: 960, height: 600)
        ])
    }

    func testInitialNarrowWindowDoesNotRequireLiveResize() {
        assertPaneLayout(for: [NSSize(width: 960, height: 600)])
    }

    private func assertPaneLayout(for sizes: [NSSize], file: StaticString = #filePath, line: UInt = #line) {
        _ = NSApplication.shared
        let sidebar = NSView()
        let main = NSView()
        let root = RootSplitView(sidebar: sidebar, main: main)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: sizes[0]),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }

        for size in sizes {
            window.setContentSize(size)
            root.layoutSubtreeIfNeeded()

            XCTAssertEqual(root.bounds.size.width, size.width, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(sidebar.frame.minX, 0, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(sidebar.frame.width, 200, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(main.frame.minX, sidebar.frame.maxX, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(main.frame.maxX, root.bounds.maxX, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(main.frame.width, size.width - 200, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(sidebar.frame.height, root.bounds.height, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(main.frame.height, root.bounds.height, accuracy: 0.5, file: file, line: line)
            XCTAssertFalse(root.hasAmbiguousLayout, file: file, line: line)
            XCTAssertFalse(sidebar.hasAmbiguousLayout, file: file, line: line)
            XCTAssertFalse(main.hasAmbiguousLayout, file: file, line: line)
        }
    }
}
