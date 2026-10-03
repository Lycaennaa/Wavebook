@testable import WavebookCore
import XCTest

final class TextEditingShortcutTests: XCTestCase {
    func testCommandEditingShortcuts() {
        XCTAssertEqual(shortcut(key: "a", command: true), .selectAll)
        XCTAssertEqual(shortcut(key: "c", command: true), .copy)
        XCTAssertEqual(shortcut(key: "x", command: true), .cut)
        XCTAssertEqual(shortcut(key: "v", command: true), .paste)
        XCTAssertEqual(shortcut(key: "z", command: true), .undo)
        XCTAssertEqual(shortcut(key: "z", command: true, shift: true), .redo)
    }

    func testControlSelectAllPolicyHandlesControlCharacter() {
        XCTAssertEqual(
            shortcut(key: "\u{1}", control: true, policy: .selectAll),
            .selectAll
        )
        XCTAssertNil(shortcut(key: "c", control: true, policy: .selectAll))
    }

    func testControlPolicyAllPreservesPanelShortcuts() {
        XCTAssertEqual(shortcut(key: "c", control: true, policy: .all), .copy)
        XCTAssertEqual(shortcut(key: "z", control: true, policy: .all), .undo)
    }

    private func shortcut(
        key: String,
        command: Bool = false,
        control: Bool = false,
        shift: Bool = false,
        policy: TextEditingShortcut.ControlPolicy = .none
    ) -> TextEditingShortcut? {
        TextEditingShortcut(
            key: key,
            hasCommand: command,
            hasControl: control,
            hasShift: shift,
            controlPolicy: policy
        )
    }
}
