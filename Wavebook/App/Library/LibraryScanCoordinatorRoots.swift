import Foundation
import WavebookCore

extension LibraryScanCoordinator {
    func addRoots(_ roots: [URL]) {
        guard let database = databaseProvider() else { return }
        for root in roots {
            scanInBackground(root: root, database: database, rootAccess: .selectedFolder)
        }
    }

    func removeRoot(_ root: LibraryRoot) async {
        guard let database = databaseProvider() else { return }
        let removal = await beginRootRemoval(forRootID: root.id)
        guard isRootRemovalCurrent(forRootID: root.id, generation: removal.generation) else { return }

        let currentRoot: LibraryRoot
        do {
            guard let registeredRoot = try database.roots().first(where: { $0.id == root.id }) else {
                finishRootRemoval(forRootID: root.id, generation: removal.generation)
                for key in removal.scanKeys { finishPersistedScanRoot(key: key, succeeded: true) }
                onLibraryChanged()
                onScanStateChanged(snapshot)
                return
            }
            currentRoot = registeredRoot
        } catch {
            finishRootRemoval(forRootID: root.id, generation: removal.generation)
            for key in removal.scanKeys { finishPersistedScanRoot(key: key, succeeded: false) }
            onEvent(.error(error, message: "Could not load library folders", kind: .database))
            return
        }

        clearScanResult(for: currentRoot.path)
        do {
            _ = try database.removeRoot(id: currentRoot.id)
            finishRootRemoval(forRootID: root.id, generation: removal.generation)
            for key in removal.scanKeys { finishPersistedScanRoot(key: key, succeeded: true) }
            onEvent(.clearOperationalErrors(.database))
            onLibraryChanged()
            onScanStateChanged(snapshot)
        } catch {
            finishRootRemoval(forRootID: root.id, generation: removal.generation)
            for key in removal.scanKeys { finishPersistedScanRoot(key: key, succeeded: false) }
            onEvent(.error(error, message: "Could not remove library folder", kind: .database))
            resumeScanAfterFailedRemoval(of: currentRoot, in: database)
        }
    }

    private func preparePersistedRootScan(for root: LibraryRoot) -> AvailableRootScan {
        let resolvedBookmark = root.securityScopedBookmark.flatMap(Self.resolveSecurityScopedBookmark)
        let scanRoot = resolvedBookmark?.url ?? root.url
        let bookmarkNeedsRefresh = root.securityScopedBookmark == nil
            || resolvedBookmark == nil
            || resolvedBookmark?.isStale == true
        let bookmark = bookmarkNeedsRefresh ? Self.makeSecurityScopedBookmark(for: scanRoot) : nil
        return AvailableRootScan(
            rootID: root.id,
            scanRoot: scanRoot,
            scanKey: root.path,
            access: ScopedRootAccess(url: scanRoot),
            pathUpdate: RootPathUpdate(
                path: scanRoot.path,
                securityScopedBookmark: bookmark
            )
        )
    }

    private func resumeScanAfterFailedRemoval(of root: LibraryRoot, in database: LibraryDatabase) {
        let rootScan = preparePersistedRootScan(for: root)
        scanInBackground(
            root: rootScan.scanRoot,
            database: database,
            rootAccess: .persisted(
                rootID: rootScan.rootID,
                access: rootScan.access,
                scanKey: rootScan.scanKey,
                pathUpdate: rootScan.pathUpdate
            )
        )
    }

    func rescanPersistedRoots(
        startReplayGain: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let database = databaseProvider() else {
            completion?(false)
            return
        }
        let roots: [LibraryRoot]
        do {
            roots = try database.roots()
            onEvent(.clearOperationalErrors(.database))
        } catch {
            onEvent(.error(error, message: "Could not load library folders", kind: .database))
            completion?(false)
            return
        }

        var availableRoots: [AvailableRootScan] = []
        var allRootsPrepared = true
        for root in roots {
            guard !isRootRemovalInProgress(forRootID: root.id) else {
                allRootsPrepared = false
                continue
            }
            let rootScan = preparePersistedRootScan(for: root)
            guard FileManager.default.fileExists(atPath: rootScan.scanRoot.path) else {
                allRootsPrepared = false
                onEvent(.error(
                    LibraryDatabaseError.missingRoot(root.path),
                    message: "Could not access saved library folder",
                    kind: .database
                ))
                continue
            }
            availableRoots.append(rootScan)
        }
        guard !availableRoots.isEmpty else {
            if roots.isEmpty, startReplayGain { onReplayGainStart() }
            completion?(allRootsPrepared)
            return
        }
        beginPersistedScanBatch(
            remainingRootPaths: Set(availableRoots.map(\.scanKey)),
            succeeded: allRootsPrepared,
            completion: completion
        )
        for root in availableRoots {
            scanInBackground(
                root: root.scanRoot,
                database: database,
                rootAccess: .persisted(
                    rootID: root.rootID,
                    access: root.access,
                    scanKey: root.scanKey,
                    pathUpdate: root.pathUpdate
                ),
                startReplayGain: startReplayGain
            )
        }
    }
}
