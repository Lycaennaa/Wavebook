import AppKit
import WavebookCore

struct PlaylistPageWorkflowContext {
    let destination: PlaylistDestination
    let kind: PlaylistKind?
    let definition: PlaylistDefinition?
    let query: String
    let selectedItemIDs: [Int64]
    let isActive: Bool

    static let empty = PlaylistPageWorkflowContext(
        destination: .system(.recentlyAdded),
        kind: nil,
        definition: nil,
        query: "",
        selectedItemIDs: [],
        isActive: false
    )
}

private struct PlaylistEditorSettings {
    let title: String
    let definition: PlaylistDefinition
    let allowsKindSelection: Bool
    let requiresName: Bool
}

private enum PlaylistEditorOperation {
    case create
    case editSmart(PlaylistDefinition)

    var settings: PlaylistEditorSettings {
        switch self {
        case .create:
            return PlaylistEditorSettings(
                title: "Create Playlist",
                definition: .manual,
                allowsKindSelection: true,
                requiresName: true
            )
        case let .editSmart(definition):
            return PlaylistEditorSettings(
                title: "Edit Smart Playlist",
                definition: definition,
                allowsKindSelection: false,
                requiresName: false
            )
        }
    }
}

@MainActor
final class PlaylistPageWorkflow {
    private let databaseProvider: () -> LibraryDatabase?
    private let contextProvider: () -> PlaylistPageWorkflowContext
    private let mutationCoordinator = PlaylistMutationCoordinator()
    private var callbackGeneration = UUID()
    private var needsRefresh = false
    var onError: ((Error) -> Void)?
    var onPlaylistMutation: (() -> Void)?
    var onSelectDestination: ((PlaylistDestination) -> Void)?
    var onPlaylistDeleted: ((Int64) -> Void)?
    var onRefresh: (() -> Void)?
    var onStateChanged: (() -> Void)?

    var isRunning: Bool { mutationCoordinator.isRunning }

    init(
        databaseProvider: @escaping () -> LibraryDatabase?,
        contextProvider: @escaping () -> PlaylistPageWorkflowContext
    ) {
        self.databaseProvider = databaseProvider
        self.contextProvider = contextProvider
    }

    func cancel() {
        callbackGeneration = UUID()
        mutationCoordinator.cancel()
        onStateChanged?()
    }
    func resetPendingRefresh() {
        needsRefresh = false
    }

    func activate() {
        guard needsRefresh else { return }
        needsRefresh = false
        onRefresh?()
    }

    func create() {
        presentEditor(.create) { [weak self] values in
            guard let self else { return }
            let origin = self.contextProvider().destination
            self.performMutation({ database in
                try database.createPlaylist(name: values.name, definition: values.definition)
            }, notifyCatalog: true, completion: { [weak self] playlist in
                guard let self, self.contextProvider().isActive,
                      self.contextProvider().destination == origin else { return }
                self.onSelectDestination?(.user(playlist.id))
            })
        }
    }

    func renameCurrent() {
        guard case let .user(id) = contextProvider().destination else { return }
        rename(playlistID: id)
    }

    func rename(playlistID id: Int64) {
        guard let database = databaseProvider() else { return }
        do {
            guard let playlist = try database.playlist(id: id) else { return }
            promptForName("Rename Playlist", initial: playlist.name) { [weak self] name in
                self?.performMutation({ database in
                    try database.renamePlaylist(id: id, to: name)
                }, notifyCatalog: true, onCommit: { [weak self] in
                    self?.refreshIfCurrent(.user(id))
                }, completion: { _ in })
            }
        } catch { onError?(error) }
    }

    func editSmart() {
        let context = contextProvider()
        guard case let .user(id) = context.destination,
              case .smart = context.definition,
              let definition = context.definition else { return }
        presentEditor(.editSmart(definition)) { [weak self] values in
            guard let self,
                  case let .smart(rulesJSON, sortField, sortDescending) = values.definition else { return }
            self.performMutation({ database in
                try database.updateSmartPlaylist(
                    id: id,
                    rulesJSON: rulesJSON,
                    sortField: sortField,
                    sortDescending: sortDescending
                )
            }, onCommit: { [weak self] in
                self?.refreshIfCurrent(.user(id))
                }, completion: { _ in })
        }
    }

    func deleteCurrent() {
        guard case let .user(id) = contextProvider().destination else { return }
        delete(playlistID: id)
    }

    func delete(playlistID id: Int64) {
        guard let database = databaseProvider() else { return }
        do {
            guard let playlist = try database.playlist(id: id) else { return }
            let alert = NSAlert()
            alert.messageText = "Delete \(playlist.name)?"
            alert.informativeText = "This cannot be undone. Tracks remain in your library."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            performMutation({ database in
                try database.deletePlaylist(id: id)
            }, notifyCatalog: true, onCommit: { [weak self] in
                self?.onPlaylistDeleted?(id)
            }, completion: { _ in })
        } catch { onError?(error) }
    }

    func clearUnavailable() {
        let context = contextProvider()
        guard case let .user(id) = context.destination, context.kind == .manual else { return }
        refreshAfterCommit(for: context.destination) { database in
            try database.clearUnavailablePlaylistItems(playlistID: id)
        }
    }

    func removeSelected() {
        let context = contextProvider()
        guard case .user = context.destination,
              context.kind == .manual,
              !context.selectedItemIDs.isEmpty else { return }
        refreshAfterCommit(for: context.destination) { database in
            try database.removePlaylistItems(ids: context.selectedItemIDs)
        }
    }

    func reorder(itemID: Int64, to ordinal: Int) {
        let context = contextProvider()
        guard case let .user(id) = context.destination,
              context.kind == .manual,
              context.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        refreshAfterCommit(for: context.destination) { database in
            try database.reorderPlaylistItem(playlistID: id, itemID: itemID, toOrdinal: ordinal)
        }
    }

    private func refreshAfterCommit(
        for destination: PlaylistDestination,
        operation: @escaping @Sendable (LibraryDatabase) throws -> Void
    ) {
        performMutation(operation, onCommit: { [weak self] in
            self?.refreshIfCurrent(destination)
        }, completion: { _ in })
    }

    private func refreshIfCurrent(_ destination: PlaylistDestination) {
        let context = contextProvider()
        guard context.destination == destination else { return }
        guard context.isActive else {
            needsRefresh = true
            return
        }
        onRefresh?()
    }

    private func promptForName(_ title: String, initial: String = "", completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel("Playlist name")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        completion(field.stringValue)
    }

    private func presentEditor(
        _ operation: PlaylistEditorOperation,
        completion: @escaping (PlaylistEditorValues) -> Void
    ) {
        let settings = operation.settings
        let editor = PlaylistEditorView(
            name: "",
            definition: settings.definition,
            allowsKindSelection: settings.allowsKindSelection
        )
        let panel = PlaylistEditorPanelController(
            title: settings.title,
            editor: editor,
            requiresName: settings.requiresName
        )
        guard let values = panel.run() else { return }
        completion(values)
    }

    private func performMutation<Output: Sendable>(
        _ operation: @escaping @Sendable (LibraryDatabase) throws -> Output,
        notifyCatalog: Bool = false,
        onCommit: @escaping @MainActor () -> Void = {},
        completion: @escaping @MainActor (Output) -> Void
    ) {
        guard let database = databaseProvider() else { return }
        let generation = UUID()
        let started = mutationCoordinator.start(
            database: database,
            operation: operation,
            onSuccess: { [weak self] result in
                guard let self else { return }
                if notifyCatalog { self.onPlaylistMutation?() }
                onCommit()
                guard self.callbackGeneration == generation else { return }
                completion(result)
            },
            onFailure: { [weak self] error in
                guard let self, self.callbackGeneration == generation else { return }
                self.onError?(error)
            },
            onFinished: { [weak self] in self?.onStateChanged?() }
        )
        if started { callbackGeneration = generation }
        onStateChanged?()
    }
}
