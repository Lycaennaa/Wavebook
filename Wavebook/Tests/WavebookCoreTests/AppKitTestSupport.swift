import AppKit
import XCTest

@MainActor
func appKitDescendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    var result: [T] = []
    for subview in root.subviews {
        if let matchingView = subview as? T { result.append(matchingView) }
        result.append(contentsOf: appKitDescendants(of: type, in: subview))
    }
    return result
}

@MainActor
func sendAppKitAction(_ control: NSControl, file: StaticString = #filePath, line: UInt = #line) {
    guard let action = control.action else {
        XCTFail("Control has no action", file: file, line: line)
        return
    }
    XCTAssertTrue(NSApp.sendAction(action, to: control.target, from: control), file: file, line: line)
}
