import AppKit
import WavebookCore

@MainActor
struct LibraryFolderSettingsActions {
    let roots: @MainActor () -> [LibraryRoot]
    let add: @MainActor ([URL]) -> Void
    let remove: @MainActor (LibraryRoot) async -> Void
}

@MainActor
final class LibraryFoldersSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private var actions: LibraryFolderSettingsActions?
    private var roots: [LibraryRoot] = []
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No library folders added.")
    private let addButton = NSButton(title: "Add Folder…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Selected", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: "Library folders")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = AppTheme.primaryText
        let details = NSTextField(
            wrappingLabelWithString: "Removing a folder removes its tracks from Wavebook, "
                + "but never deletes files from disk."
        )
        details.textColor = AppTheme.secondaryText
        details.maximumNumberOfLines = 2
        emptyLabel.textColor = AppTheme.secondaryText

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("libraryRoot"))
        column.width = 570
        table.addTableColumn(column)
        table.headerView = nil
        table.allowsMultipleSelection = false
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = table
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        table.frame = NSRect(x: 0, y: 0, width: 584, height: 86)

        addButton.target = self
        addButton.action = #selector(addFolder)
        addButton.bezelStyle = .rounded
        addButton.contentTintColor = AppTheme.accent
        addButton.setAccessibilityLabel("Add Library Folder")
        removeButton.target = self
        removeButton.action = #selector(removeSelectedFolder)
        removeButton.bezelStyle = .rounded
        removeButton.contentTintColor = AppTheme.accent
        removeButton.setAccessibilityLabel("Remove Selected Library Folder")
        removeButton.isEnabled = false
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        let stack = NSStackView(views: [title, details, scrollView, emptyLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            details.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 86),
            emptyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ actions: LibraryFolderSettingsActions) {
        self.actions = actions
        set(roots: actions.roots())
    }

    private func set(roots: [LibraryRoot]) {
        self.roots = roots
        table.reloadData()
        table.deselectAll(nil)
        table.setFrameSize(NSSize(width: 584, height: max(86, CGFloat(roots.count) * table.rowHeight)))
        emptyLabel.isHidden = !roots.isEmpty
        removeButton.isEnabled = false
    }

    @objc private func addFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let actions = self.actions else { return }
            actions.add(panel.urls)
            self.set(roots: actions.roots())
        }
    }

    @objc private func removeSelectedFolder() {
        guard let window,
              table.selectedRow >= 0,
              roots.indices.contains(table.selectedRow) else { return }
        let root = roots[table.selectedRow]
        let alert = NSAlert()
        alert.messageText = "Remove Library Folder?"
        alert.informativeText = "Remove \(root.path) and its indexed tracks from Wavebook? "
            + "Files on disk will not be deleted."
        alert.addButton(withTitle: "Remove Folder")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor [weak self] in
                guard let self, let actions = self.actions else { return }
                self.addButton.isEnabled = false
                self.removeButton.isEnabled = false
                await actions.remove(root)
                self.set(roots: actions.roots())
                self.addButton.isEnabled = true
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        roots.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard roots.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("libraryRootPath")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.stringValue = roots[row].path
        cell.lineBreakMode = .byTruncatingMiddle
        cell.toolTip = roots[row].path
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0
    }
}
