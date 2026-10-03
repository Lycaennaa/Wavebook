import Foundation

public enum TextEditingShortcut: Equatable {
    public enum ControlPolicy {
        case none
        case selectAll
        case all
    }

    case selectAll
    case copy
    case cut
    case paste
    case undo
    case redo

    private static let controlACharacter = "\u{1}"

    public init?(
        key: String,
        hasCommand: Bool,
        hasControl: Bool,
        hasShift: Bool,
        controlPolicy: ControlPolicy
    ) {
        let key = key.lowercased()
        let isSelectAllKey = key == "a" || key == Self.controlACharacter
        let allowsControl = Self.allowsControl(controlPolicy, forSelectAllKey: isSelectAllKey)
        guard hasCommand || (hasControl && allowsControl) else { return nil }

        switch key {
        case "a": self = .selectAll
        case "c": self = .copy
        case "x": self = .cut
        case "v": self = .paste
        case "z": self = hasShift ? .redo : .undo
        default:
            guard isSelectAllKey else { return nil }
            self = .selectAll
        }
    }

    private static func allowsControl(_ policy: ControlPolicy, forSelectAllKey isSelectAllKey: Bool) -> Bool {
        switch policy {
        case .none: false
        case .selectAll: isSelectAllKey
        case .all: true
        }
    }
}
