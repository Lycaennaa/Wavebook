enum OperationalErrorKind: Sendable, Hashable {
    case database
    case libraryScan
    case audioOutput
    case general
}
