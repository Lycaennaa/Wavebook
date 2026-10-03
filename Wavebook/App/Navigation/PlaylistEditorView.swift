import AppKit
import WavebookCore

struct PlaylistEditorValues {
    let name: String
    let definition: PlaylistDefinition
}

final class PlaylistEditorView: NSView {
    static let preferredWidth: CGFloat = 440
    private let nameField: NSTextField
    private let kindPopup = NSPopUpButton()
    private let rulesLabel = NSTextField(labelWithString: "Rules JSON")
    private let rulesView = NSTextView()
    private let rulesScrollView = NSScrollView()
    private let sortPopup = NSPopUpButton()
    private let descendingButton = NSButton(checkboxWithTitle: "Descending", target: nil, action: nil)
    private let smartControls = NSStackView()
    private let contentStack = NSStackView()
    private var shouldApplySmartDefaults: Bool

    init(name: String, definition: PlaylistDefinition?, allowsKindSelection: Bool) {
        nameField = NSTextField(string: name)
        shouldApplySmartDefaults = allowsKindSelection && (definition == nil || definition?.kind == .manual)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: 0))
        configure(definition: definition, allowsKindSelection: allowsKindSelection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    func focusNameField() {
        window?.makeFirstResponder(nameField)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.preferredWidth, height: contentStack.fittingSize.height)
    }

    var values: PlaylistEditorValues {
        let definition: PlaylistDefinition
        if kindPopup.indexOfSelectedItem == 0 {
            definition = .manual
        } else {
            let rawValue = sortPopup.selectedItem?.representedObject as? String ?? PlaylistSortField.album.rawValue
            let sortField = PlaylistSortField(rawValue: rawValue) ?? .album
            definition = .smart(
                rulesJSON: rulesView.string,
                sortField: sortField,
                sortDescending: descendingButton.state == .on
            )
        }
        return PlaylistEditorValues(name: nameField.stringValue, definition: definition)
    }

    private func configure(definition: PlaylistDefinition?, allowsKindSelection: Bool) {
        nameField.placeholderString = "Playlist name"
        nameField.setAccessibilityLabel("Playlist name")
        kindPopup.addItems(withTitles: ["Manual", "Smart"])
        kindPopup.isEnabled = allowsKindSelection
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged)
        rulesLabel.font = .systemFont(ofSize: 12, weight: .medium)
        rulesView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        rulesView.string = "{\"rules\":[]}"
        rulesView.isRichText = false
        rulesView.isVerticallyResizable = true
        rulesView.isHorizontallyResizable = false
        rulesView.autoresizingMask = [.width]
        rulesScrollView.borderType = .bezelBorder
        rulesScrollView.hasVerticalScroller = true
        rulesScrollView.documentView = rulesView
        rulesScrollView.heightAnchor.constraint(equalToConstant: 100).isActive = true
        sortPopup.addItems(withTitles: PlaylistSortField.allCases.map(Self.displayName))
        for (index, field) in PlaylistSortField.allCases.enumerated() {
            sortPopup.item(at: index)?.representedObject = field.rawValue
        }
        descendingButton.setAccessibilityLabel("Descending")
        smartControls.orientation = .vertical
        smartControls.alignment = .leading
        smartControls.spacing = 5
        smartControls.detachesHiddenViews = true
        smartControls.addArrangedSubview(rulesLabel)
        smartControls.addArrangedSubview(rulesScrollView)
        smartControls.addArrangedSubview(sortPopup)
        smartControls.addArrangedSubview(descendingButton)
        smartControls.translatesAutoresizingMaskIntoConstraints = false

        let kindRow = NSStackView(views: [NSView(), kindPopup])
        kindRow.orientation = .horizontal
        kindRow.alignment = .centerY
        kindRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = contentStack
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(kindRow)
        stack.addArrangedSubview(smartControls)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        if let definition {
            apply(definition)
        }
        kindChanged()
    }

    private func apply(_ definition: PlaylistDefinition) {
        switch definition {
        case .manual:
            kindPopup.selectItem(at: 0)
        case let .smart(rulesJSON, sortField, sortDescending):
            kindPopup.selectItem(at: 1)
            rulesView.string = rulesJSON
            sortPopup.selectItem(at: PlaylistSortField.allCases.firstIndex(of: sortField) ?? 0)
            descendingButton.state = sortDescending ? .on : .off
        }
    }

    @objc private func kindChanged() {
        if kindPopup.indexOfSelectedItem == 1, shouldApplySmartDefaults {
            sortPopup.selectItem(at: PlaylistSortField.allCases.firstIndex(of: .firstSeen) ?? 0)
            descendingButton.state = .on
            shouldApplySmartDefaults = false
        }
        smartControls.isHidden = kindPopup.indexOfSelectedItem == 0
        invalidateIntrinsicContentSize()
    }

    private static func displayName(_ field: PlaylistSortField) -> String {
        switch field {
        case .album: return "Album"
        case .firstSeen: return "First Seen"
        case .qualifiedPlays: return "Qualified Plays"
        case .duration: return "Duration"
        }
    }
}
