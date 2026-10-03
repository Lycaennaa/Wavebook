import AppKit
import WavebookCore

private final class ShortcutAwareWindow: NSWindow {
    private weak var searchField: NSSearchField?

    init(searchField: NSSearchField) {
        self.searchField = searchField
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let didBecomeFirstResponder = super.makeFirstResponder(responder)
        guard didBecomeFirstResponder,
              let editor = firstResponder as? NSTextView,
              isSearchFieldEditor(editor) else {
            return didBecomeFirstResponder
        }
        configureSelection(in: editor)
        return didBecomeFirstResponder
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown,
              let editor = searchFieldEditor(),
              let shortcut = TextEditingShortcut(event: event, controlPolicy: .selectAll) else {
            super.sendEvent(event)
            return
        }

        if case .selectAll = shortcut {
            selectAll(in: editor)
        } else {
            shortcut.perform(on: editor)
        }
    }

    private func searchFieldEditor() -> NSTextView? {
        guard let editor = firstResponder as? NSTextView,
              editor.isFieldEditor,
              isSearchFieldEditor(editor) else {
            return nil
        }
        return editor
    }

    private func isSearchFieldEditor(_ editor: NSTextView) -> Bool {
        guard let searchField else { return false }
        return searchField.currentEditor() === editor
    }

    private func configureSelection(in editor: NSTextView) {
        editor.selectedTextAttributes = [
            .backgroundColor: AppTheme.accent,
            .foregroundColor: AppTheme.textOnAccent
        ]
    }

    private func selectAll(in editor: NSTextView) {
        configureSelection(in: editor)
        editor.selectAll(nil)
        editor.needsDisplay = true
    }
}

@MainActor
final class MainWindowController: NSWindowController {
    private let root: RootSplitViewController

    init() {
        let searchField = NSSearchField()
        root = RootSplitViewController(searchField: searchField)
        let window = ShortcutAwareWindow(searchField: searchField)
        window.title = ""
        window.appearance = AppTheme.appearance.nsAppearance
        window.backgroundColor = AppTheme.background
        window.minSize = NSSize(width: 960, height: 600)
        window.titlebarAppearsTransparent = true
        window.contentView = root.view
        window.center()
        super.init(window: window)
        installResizeObservers(on: window)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func installResizeObservers(on window: NSWindow) {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(liveResizeWillStart),
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(liveResizeDidEnd),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
    }

    @objc private func liveResizeWillStart() {
        root.beginLiveResize()
    }

    @objc private func liveResizeDidEnd() {
        root.endLiveResize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func handleMediaKey(_ command: MediaKeyCommand) -> Bool {
        root.handleMediaKey(command)
    }

    func addRoot() {
        root.addRoot()
    }

    func showSettings() {
        root.showSettings()
    }

    func prepareForTermination(completion: @escaping @MainActor (Bool) -> Void) {
        root.prepareForTermination(completion: completion)
    }
}
