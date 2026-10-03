import AppKit
import WavebookCore

extension TextEditingShortcut {
    init?(event: NSEvent, controlPolicy: ControlPolicy) {
        guard let key = event.charactersIgnoringModifiers else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.init(
            key: key,
            hasCommand: modifiers.contains(.command),
            hasControl: modifiers.contains(.control),
            hasShift: modifiers.contains(.shift),
            controlPolicy: controlPolicy
        )
    }

@MainActor
    func perform(on editor: NSTextView) {
        switch self {
        case .selectAll:
            editor.selectAll(nil)
        case .copy:
            editor.copy(nil)
        case .cut:
            editor.cut(nil)
        case .paste:
            editor.paste(nil)
        case .undo:
            editor.undoManager?.undo()
        case .redo:
            editor.undoManager?.redo()
        }
    }
}
