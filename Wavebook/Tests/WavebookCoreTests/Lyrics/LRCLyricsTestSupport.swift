import Foundation
@testable import WavebookCore
import XCTest

final class LyricAssociationQueryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [LyricAssociationQueryEvent] = []

    func append(_ event: LyricAssociationQueryEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    func events(for keyColumn: String) -> [LyricAssociationQueryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents.filter { $0.keyColumn == keyColumn }
    }
}

final class LRCLyricsTests: XCTestCase {

    func makeRoot() throws -> URL {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".test-tmp")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
