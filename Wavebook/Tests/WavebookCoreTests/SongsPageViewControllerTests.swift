import AppKit
import WavebookCore
import XCTest

@MainActor
final class SongsPageViewControllerTests: XCTestCase {
    func testRowsStayLeftAlignedAndFillViewportAcrossWindowResizes() throws {
        _ = NSApplication.shared
        let controller = SongsPageViewController()
        let pageView = controller.view
        let scrollView = try XCTUnwrap(findScrollView(in: pageView))
        let collectionView = try XCTUnwrap(scrollView.documentView as? NSCollectionView)
        let main = ThemeBackgroundView()
        let root = RootSplitView(sidebar: NSView(), main: main)
        main.addSubview(pageView)
        pageView.translatesAutoresizingMaskIntoConstraints = true
        pageView.frame = main.bounds
        pageView.autoresizingMask = [.width, .height]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer {
            controller.deactivate()
            window.close()
        }

        controller.setTracks((0..<20).map { index in
            Track(
                id: Int64(index + 1),
                path: FileManager.default.currentDirectoryPath + "/.build/missing-resize-track-\(index).flac",
                title: "Track \(index + 1)",
                artistDisplay: "Artist",
                albumTitle: "Album",
                albumArtist: "Artist",
                genreDisplay: "Rock",
                duration: 180,
                format: "flac",
                hasLyrics: false,
                firstSeenAtUTC: Date(timeIntervalSince1970: 0)
            )
        })
        root.layoutSubtreeIfNeeded()
        collectionView.layoutSubtreeIfNeeded()
        let selection: Set<IndexPath> = [IndexPath(item: 1, section: 0)]
        collectionView.selectionIndexPaths = selection

        for width: CGFloat in [1_180, 1_800, 960, 1_400, 960] {
            window.setContentSize(NSSize(width: width, height: 760))
            root.layoutSubtreeIfNeeded()
            collectionView.layoutSubtreeIfNeeded()

            let viewportWidth = scrollView.contentView.bounds.width
            XCTAssertEqual(collectionView.frame.width, viewportWidth, accuracy: 0.5, "Window width: \(width)")
            XCTAssertEqual(scrollView.frame.width, width - 200, accuracy: 0.5)
            XCTAssertEqual(collectionView.selectionIndexPaths, selection)

            try assertVisibleRows(in: collectionView, root: root)
        }

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertEqual(scrollView.contentView.bounds.minY, 400, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentView.bounds.minX, 0, accuracy: 0.5)
    }

    private func assertVisibleRows(in collectionView: NSCollectionView, root: NSView) throws {
        let viewportWidth = try XCTUnwrap(collectionView.enclosingScrollView).contentView.bounds.width
        for index in 0..<3 {
            let context = "Window width: \(root.bounds.width), row: \(index)"
            let indexPath = IndexPath(item: index, section: 0)
            let attributes = try XCTUnwrap(collectionView.layoutAttributesForItem(at: indexPath))
            let rowFrame = collectionView.convert(attributes.frame, to: root)
            XCTAssertEqual(rowFrame.minX, 216, accuracy: 0.5, context)
            XCTAssertEqual(rowFrame.width, viewportWidth - 32, accuracy: 0.5, context)
            XCTAssertEqual(attributes.frame.minY, 12 + CGFloat(index) * 81, accuracy: 0.5)
            let item = try XCTUnwrap(collectionView.item(at: indexPath))
            item.view.layoutSubtreeIfNeeded()
            let itemFrame = item.view.convert(item.view.bounds, to: root)
            XCTAssertEqual(itemFrame.minX, rowFrame.minX, accuracy: 0.5, context)
            XCTAssertEqual(itemFrame.width, rowFrame.width, accuracy: 0.5, context)
            let artwork = try XCTUnwrap(item.view.subviews.first { $0 is NSImageView })
            let artworkFrame = artwork.convert(artwork.bounds, to: root)
            XCTAssertEqual(artworkFrame.minX, 226, accuracy: 0.5, context)
        }
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }
}
