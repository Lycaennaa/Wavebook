import Foundation
import GRDB

public enum RootPathResolutionError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case symlinkLoop(path: String)
    case symlinkResolutionLimitExceeded(path: String, limit: Int)
    case symlinkResolutionFailed(path: String, componentPath: String, reason: String)

    public var description: String {
        switch self {
        case .symlinkLoop:
            return "Symbolic-link loop while resolving path"
        case let .symlinkResolutionLimitExceeded(_, limit):
            return "Symbolic-link resolution exceeded the \(limit)-link limit"
        case let .symlinkResolutionFailed(_, componentPath, reason):
            return "Could not resolve path component \(componentPath): \(reason)"
        }
    }

    public var errorDescription: String? { description }
}

struct RootPathIdentity {
    let path: String
    let isCaseSensitive: Bool?
}

extension LibraryDatabase {
    static let rootSymlinkResolutionLimit = 64

    private enum SymbolicLinkLookupResult {
        case destination(String)
        case ordinaryComponent
        case missingSuffix
    }

    private struct RootPathResolutionState {
        var pending: [String]
        var resolved: [String]
        var visitedSymlinkStates: Set<String>
        var symlinkDepth: Int
        var index: Int
    }

    static func resolveRootPath(
        _ path: String,
        destinationOfSymbolicLink: (String) throws -> String = { path in
            try FileManager.default.destinationOfSymbolicLink(atPath: path)
        }
    ) throws -> String {
        let absolutePath = URL(fileURLWithPath: path, isDirectory: true).absoluteURL.path
        var state = RootPathResolutionState(
            pending: absolutePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init),
            resolved: [],
            visitedSymlinkStates: [],
            symlinkDepth: 0,
            index: 0
        )

        while state.index < state.pending.count {
            let component = state.pending[state.index]
            state.index += 1
            if component == "." {
                continue
            }
            if component == ".." {
                if !state.resolved.isEmpty { state.resolved.removeLast() }
                continue
            }

            let candidate = "/" + (state.resolved + [component]).joined(separator: "/")
            switch try symbolicLinkLookupResult(
                atPath: candidate,
                originalPath: absolutePath,
                destinationOfSymbolicLink: destinationOfSymbolicLink
            ) {
            case let .destination(destination):
                try applySymlinkDestination(
                    destination,
                    absolutePath: absolutePath,
                    candidate: candidate,
                    state: &state
                )
            case .ordinaryComponent:
                state.resolved.append(component)
            case .missingSuffix:
                state.resolved.append(component)
                appendMissingSuffix(to: &state)
            }
        }

        return state.resolved.isEmpty ? "/" : "/" + state.resolved.joined(separator: "/")
    }

    private static func applySymlinkDestination(
        _ destination: String,
        absolutePath: String,
        candidate: String,
        state: inout RootPathResolutionState
    ) throws {
        let visitedState = candidate + "\u{0}" + state.pending[state.index...].joined(separator: "\u{0}")
        guard state.visitedSymlinkStates.insert(visitedState).inserted else {
            throw RootPathResolutionError.symlinkLoop(path: absolutePath)
        }
        guard state.symlinkDepth < rootSymlinkResolutionLimit else {
            throw RootPathResolutionError.symlinkResolutionLimitExceeded(
                path: absolutePath,
                limit: rootSymlinkResolutionLimit
            )
        }
        state.symlinkDepth += 1
        if destination.hasPrefix("/") {
            state.resolved.removeAll(keepingCapacity: true)
        }
        state.pending = destination.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            + Array(state.pending[state.index...])
        state.index = 0
    }

    private static func appendMissingSuffix(to state: inout RootPathResolutionState) {
        while state.index < state.pending.count {
            let suffixComponent = state.pending[state.index]
            state.index += 1
            switch suffixComponent {
            case ".":
                continue
            case "..":
                if !state.resolved.isEmpty { state.resolved.removeLast() }
            default:
                state.resolved.append(suffixComponent)
            }
        }
    }

    private static func symbolicLinkLookupResult(
        atPath candidatePath: String,
        originalPath: String,
        destinationOfSymbolicLink: (String) throws -> String
    ) throws -> SymbolicLinkLookupResult {
        do {
            let destination = try destinationOfSymbolicLink(candidatePath)
            return destination.isEmpty ? .ordinaryComponent : .destination(destination)
        } catch {
            let foundationError = error as NSError
            if foundationError.domain == NSCocoaErrorDomain,
               foundationError.code == CocoaError.Code.fileReadNoSuchFile.rawValue {
                return .missingSuffix
            }
            if let posixCode = posixErrorCode(in: foundationError) {
                switch posixCode {
                case POSIXErrorCode.ENOENT.rawValue, POSIXErrorCode.ENOTDIR.rawValue:
                    return .missingSuffix
                case POSIXErrorCode.EINVAL.rawValue:
                    return .ordinaryComponent
                case POSIXErrorCode.ELOOP.rawValue:
                    throw RootPathResolutionError.symlinkLoop(path: originalPath)
                default:
                    break
                }
            }
            throw RootPathResolutionError.symlinkResolutionFailed(
                path: originalPath,
                componentPath: candidatePath,
                reason: rootResolutionFailureReason(for: foundationError)
            )
        }
    }

    private static func posixErrorCode(in error: NSError) -> Int32? {
        var current: NSError? = error
        var visited = Set<ObjectIdentifier>()
        while let currentError = current,
              visited.insert(ObjectIdentifier(currentError)).inserted {
            if currentError.domain == NSPOSIXErrorDomain {
                return Int32(currentError.code)
            }
            current = currentError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    private static func rootResolutionFailureReason(for error: NSError) -> String {
        let description = error.localizedDescription
        var reason = description.isEmpty
            ? "\(error.domain) error \(error.code)"
            : "\(error.domain) error \(error.code): \(description)"
        if let posixCode = posixErrorCode(in: error), error.domain != NSPOSIXErrorDomain {
            reason += " (POSIX error \(posixCode))"
        }
        return String(reason.prefix(256))
    }

    // Kept for non-root callers that still use the historical non-throwing helper.
    static func canonicalRootPath(_ path: String) -> String {
        (try? resolveRootPath(path)) ?? lexicalRootPath(path)
    }

    private static func lexicalRootPath(_ path: String) -> String {
        let absolutePath = URL(fileURLWithPath: path, isDirectory: true).absoluteURL.path
        var resolved: [String] = []
        for component in absolutePath.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !resolved.isEmpty { resolved.removeLast() }
            default:
                resolved.append(String(component))
            }
        }
        return resolved.isEmpty ? "/" : "/" + resolved.joined(separator: "/")
    }

    static func canonicalPathIdentityKey(_ path: String) throws -> String {
        let canonicalPath = try resolveRootPath(path)
        guard volumeSupportsCaseSensitiveNames(at: canonicalPath) == false else { return canonicalPath }
        return canonicalPath.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func rootPathsOverlap(_ lhs: String, _ rhs: String) throws -> Bool {
        try rootPathsOverlap(rootPathIdentity(for: lhs), rootPathIdentity(for: rhs))
    }

    static func canonicalPathIsContained(
        _ candidatePath: String,
        in rootPath: String,
        caseSensitive: Bool? = nil
    ) -> Bool {
        let rootComponents = pathComponents(rootPath)
        let candidateComponents = pathComponents(candidatePath)
        guard candidateComponents.count > rootComponents.count else { return false }
        let sensitivity = caseSensitive ?? volumeSupportsCaseSensitiveNames(at: rootPath) ?? true
        return zip(rootComponents, candidateComponents).allSatisfy {
            rootComponentsMatch($0.0, $0.1, isCaseSensitive: sensitivity)
        }
    }

    static func canonicalPath(_ path: String, underRoot rootPath: String) throws -> String {
        let rootIdentity = try rootPathIdentity(for: rootPath)
        let canonicalPath = try resolveRootPath(path)
        guard canonicalPathIsContained(
            canonicalPath,
            in: rootIdentity.path,
            caseSensitive: rootIdentity.isCaseSensitive
        ) else {
            throw LibraryDatabaseError.pathOutsideRoot(canonicalPath, rootPath: rootIdentity.path)
        }
        return canonicalPath
    }

    static func canonicalPathWithUnresolvedLeaf(_ path: String, underRoot rootPath: String) throws -> String {
        let rootIdentity = try rootPathIdentity(for: rootPath)
        let candidateURL = URL(fileURLWithPath: path).standardizedFileURL
        let parentPath = try resolveRootPath(candidateURL.deletingLastPathComponent().path)
        let candidatePath = URL(fileURLWithPath: parentPath, isDirectory: true)
            .appendingPathComponent(candidateURL.lastPathComponent)
            .standardizedFileURL.path
        guard canonicalPathIsContained(
            candidatePath,
            in: rootIdentity.path,
            caseSensitive: rootIdentity.isCaseSensitive
        ) else {
            throw LibraryDatabaseError.pathOutsideRoot(candidatePath, rootPath: rootIdentity.path)
        }
        return candidatePath
    }

    static func canonicalPathPreservingUnresolvedLeaf(_ path: String, underRoot rootPath: String) throws -> String {
        do {
            return try canonicalPath(path, underRoot: rootPath)
        } catch is RootPathResolutionError {
            return try canonicalPathWithUnresolvedLeaf(path, underRoot: rootPath)
        }
    }

    static func ensureRoot(path: String, db database: Database) throws -> Int64 {
        let requestedIdentity = try rootPathIdentity(for: path)
        let rows = try Row.fetchAll(database, sql: "SELECT id, path FROM roots ORDER BY id")
        var matchingRootID: Int64?
        for row in rows {
            let existingPath: String = row["path"]
            let existingIdentity = try rootPathIdentity(for: existingPath)
            if rootPathIdentityMatches(requestedIdentity, existingIdentity) {
                matchingRootID = matchingRootID ?? row["id"]
            } else if rootPathsOverlap(requestedIdentity, existingIdentity) {
                throw LibraryDatabaseError.overlappingRoot(requestedIdentity.path, existingPath: existingPath)
            }
        }
        if let matchingRootID { return matchingRootID }

        try database.execute(
            sql: "INSERT INTO roots (path, lastScanAt) VALUES (?, NULL)",
            arguments: [requestedIdentity.path]
        )
        guard let rootID = try Int64.fetchOne(
            database,
            sql: "SELECT id FROM roots WHERE path = ?",
            arguments: [requestedIdentity.path]
        ) else {
            throw LibraryDatabaseError.missingRoot(requestedIdentity.path)
        }
        return rootID
    }

    static func rootID(matching path: String, db database: Database) throws -> Int64? {
        let requestedIdentity = try rootPathIdentity(for: path)
        if let exactID = try Int64.fetchOne(
            database,
            sql: "SELECT id FROM roots WHERE path = ?",
            arguments: [requestedIdentity.path]
        ) {
            return exactID
        }
        let rows = try Row.fetchAll(database, sql: "SELECT id, path FROM roots ORDER BY id")
        for row in rows {
            let existingPath: String = row["path"]
            if rootPathIdentityMatches(requestedIdentity, try rootPathIdentity(for: existingPath)) {
                return row["id"]
            }
        }
        return nil
    }

    static func rootPath(forID rootID: Int64, db database: Database) throws -> String? {
        guard let path = try String.fetchOne(
            database,
            sql: "SELECT path FROM roots WHERE id = ?",
            arguments: [rootID]
        ) else {
            return nil
        }
        return try resolveRootPath(path)
    }

    /// Adds a library root and returns its identifier.
    @discardableResult
    public func addRoot(path: String) throws -> Int64 {
        try writer.write { database in
            try Self.ensureRoot(path: path, db: database)
        }
    }

    /// Returns all configured library roots.
    public func roots() throws -> [LibraryRoot] {
        try writer.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT id, path, lastScanAt FROM roots ORDER BY path COLLATE NOCASE, path"
            )
            return try rows.map { row in
                let path: String = row["path"]
                return LibraryRoot(
                    id: row["id"],
                    path: try Self.resolveRootPath(path),
                    lastScanAt: row["lastScanAt"]
                )
            }
        }
    }
    /// Removes a library root and its indexed catalog data.
    @discardableResult
    public func removeRoot(id: Int64) throws -> Bool {
        try writer.write { database in
            guard try Int64.fetchOne(
                database,
                sql: "SELECT id FROM roots WHERE id = ?",
                arguments: [id]
            ) != nil else { return false }
            let tracks = try Row.fetchCursor(
                database,
                sql: "SELECT id, albumTitle, albumArtist, artistDisplay FROM tracks WHERE rootId = ?",
                arguments: [id]
            )
            var albumKeys = Set<AlbumKey>()
            while let row = try tracks.next() {
                try Self.checkCatalogCancellation()
                if let albumKey = Self.albumKey(from: row) {
                    albumKeys.insert(albumKey)
                }
                let trackID: Int64 = row["id"]
                try Self.deleteTrackPreservingPlaylistIdentity(trackID: trackID, db: database)
            }
            try Self.reattachOrphanedPlaylistItems(db: database)
            try Self.invalidateAlbumValues(for: albumKeys, db: database)
            try database.execute(sql: "DELETE FROM roots WHERE id = ?", arguments: [id])
            try Self.deleteOrphanNames(database: database)
            return true
        }
    }

    private static func rootPathsOverlap(_ lhs: RootPathIdentity, _ rhs: RootPathIdentity) -> Bool {
        rootPathIdentityMatches(lhs, rhs) || rootContains(lhs, rhs) || rootContains(rhs, lhs)
    }

    static func rootPathIdentity(for path: String) throws -> RootPathIdentity {
        let canonicalPath = try resolveRootPath(path)
        return RootPathIdentity(
            path: canonicalPath,
            isCaseSensitive: volumeSupportsCaseSensitiveNames(at: canonicalPath)
        )
    }

    private static func volumeSupportsCaseSensitiveNames(at path: String) -> Bool? {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        while true {
            if let value = try? url.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey]
            ).volumeSupportsCaseSensitiveNames {
                return value
            }
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { return nil }
            url = parent
        }
    }

    static func rootPathIdentityMatches(_ lhs: RootPathIdentity, _ rhs: RootPathIdentity) -> Bool {
        let lhsComponents = pathComponents(lhs.path)
        let rhsComponents = pathComponents(rhs.path)
        guard lhsComponents.count == rhsComponents.count else { return false }
        let isCaseSensitive = lhs.isCaseSensitive != false || rhs.isCaseSensitive != false
        return zip(lhsComponents, rhsComponents).allSatisfy {
            rootComponentsMatch($0.0, $0.1, isCaseSensitive: isCaseSensitive)
        }
    }

    static func rootContains(_ parent: RootPathIdentity, _ child: RootPathIdentity) -> Bool {
        let parentComponents = pathComponents(parent.path)
        let childComponents = pathComponents(child.path)
        guard parentComponents.count < childComponents.count else { return false }
        let isCaseSensitive = parent.isCaseSensitive != false || child.isCaseSensitive != false
        return zip(parentComponents, childComponents).allSatisfy {
            rootComponentsMatch($0.0, $0.1, isCaseSensitive: isCaseSensitive)
        }
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func rootComponentsMatch(_ lhs: String, _ rhs: String, isCaseSensitive: Bool) -> Bool {
        isCaseSensitive ? lhs == rhs : lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
