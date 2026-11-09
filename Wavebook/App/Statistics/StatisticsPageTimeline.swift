import AppKit
import WavebookCore

private final class StatisticsTimelineCheckbox: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.switch)
        title = ""
        isBordered = false
        focusRingType = .default
        allowsMixedState = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    var isChecked = false {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 18, height: 18)
    }

    private var boxRect: NSRect {
        let size: CGFloat = 14
        return NSRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        ).insetBy(dx: 0.5, dy: 0.5)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: boxRect, xRadius: 3, yRadius: 3)
        if isChecked {
            let fill = AppTheme.appearance == .amoled ? NSColor.systemMint : NSColor.systemBlue
            fill.setFill()
            box.fill()
            let checkmark = NSBezierPath()
            checkmark.lineWidth = 2
            checkmark.lineCapStyle = .round
            checkmark.lineJoinStyle = .round
            checkmark.move(to: NSPoint(x: boxRect.minX + 3, y: boxRect.midY))
            checkmark.line(to: NSPoint(x: boxRect.minX + 5.5, y: boxRect.minY + 3))
            checkmark.line(to: NSPoint(x: boxRect.maxX - 2.5, y: boxRect.maxY - 3))
            (AppTheme.appearance == .amoled ? NSColor.black : NSColor.white).setStroke()
            checkmark.stroke()
        } else {
            AppTheme.background.setFill()
            box.fill()
            (isEnabled ? AppTheme.primaryText : AppTheme.secondaryText).setStroke()
            box.lineWidth = isEnabled ? 1.5 : 1
            box.stroke()
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: boxRect.insetBy(dx: -2, dy: -2),
            xRadius: 5,
            yRadius: 5
        ).fill()
    }
}

private final class StatisticsTimelineRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ListeningHistoryTimelineRow")

    private let rowStack = NSStackView()
    private let checkbox = StatisticsTimelineCheckbox(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    var onCheckboxChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 6
        rowStack.detachesHiddenViews = true
        rowStack.addArrangedSubview(checkbox)
        rowStack.addArrangedSubview(titleLabel)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            rowStack.topAnchor.constraint(equalTo: topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 18),
            checkbox.heightAnchor.constraint(equalToConstant: 18)
        ])
        checkbox.target = self
        checkbox.action = #selector(checkboxClicked)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        entry: ListeningQualifiedPlayTimelineEntry,
        timeFormatter: DateFormatter,
        selected: Bool,
        showsCheckbox: Bool,
        isSelectable: Bool
    ) {
        timeFormatter.timeZone = TimeZone(secondsFromGMT: entry.utcOffsetSeconds)
        titleLabel.stringValue = "\(timeFormatter.string(from: entry.qualifiedAtUTC)) — "
            + "\(entry.title) · \(entry.artistDisplay) · \(entry.albumTitle)"
        checkbox.state = selected ? .on : .off
        checkbox.isChecked = selected
        checkbox.isHidden = !showsCheckbox
        checkbox.isEnabled = isSelectable
        checkbox.setAccessibilityLabel("Select \(entry.title)")
    }

    @objc private func checkboxClicked() {
        let selected = checkbox.state == .on
        checkbox.isChecked = selected
        onCheckboxChange?(selected)
    }
}

private final class StatisticsTimelineRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        AppTheme.selection.setFill()
        dirtyRect.fill()
        AppTheme.primaryText.setFill()
        NSBezierPath(
            rect: NSRect(x: bounds.minX, y: bounds.minY, width: 4, height: bounds.height)
        ).fill()
    }
}

extension StatisticsPageViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        timelineEntries.count
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard timelineEntries.indices.contains(row) else { return nil }
        return StatisticsTimelineRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard timelineEntries.indices.contains(row) else { return nil }
        let entry = timelineEntries[row]
        let cell = (tableView.makeView(
            withIdentifier: StatisticsTimelineRowCell.identifier,
            owner: self
        ) as? StatisticsTimelineRowCell) ?? StatisticsTimelineRowCell(frame: .zero)
        cell.identifier = StatisticsTimelineRowCell.identifier
        cell.configure(
            entry: entry,
            timeFormatter: timeFormatter,
            selected: selectedTimelineEventIDs.contains(entry.eventID),
            showsCheckbox: isTimelineSelectionMode,
            isSelectable: entry.isFinalized && !statisticsModel.isResetInFlight
        )
        cell.onCheckboxChange = { [weak self] isSelected in
            self?.setTimelineEntry(entry.eventID, selected: isSelected)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !isTimelineSelectionMode
            && timelineEntries.indices.contains(row)
            && timelineEntries[row].isFinalized
            && !statisticsModel.isResetInFlight
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isTimelineSelectionMode else { return }
        let validIndexes = IndexSet(timelineTable.selectedRowIndexes.filter { row in
            timelineEntries.indices.contains(row)
                && timelineEntries[row].isFinalized
                && !statisticsModel.isResetInFlight
        })
        if validIndexes != timelineTable.selectedRowIndexes {
            timelineTable.selectRowIndexes(validIndexes, byExtendingSelection: false)
            return
        }
        timelineSelection.setRowSelection(validIndexes.map { timelineEntries[$0].eventID })
        updateTimelineSelectionControls()
        timelineTable.reloadData()
    }
}

extension StatisticsPageViewController {
    @objc func toggleTimelineSelectionMode() {
        if isTimelineSelectionMode {
            timelineSelection.leaveCheckboxMode()
            let selectedRows = IndexSet(timelineEntries.indices.filter {
                selectedTimelineEventIDs.contains(timelineEntries[$0].eventID)
            })
            timelineTable.selectRowIndexes(selectedRows, byExtendingSelection: false)
        } else {
            timelineSelection.enterCheckboxMode()
            timelineTable.deselectAll(nil)
        }
        selectTimelineButton.title = isTimelineSelectionMode ? "Done" : "Select"
        selectTimelineButton.setAccessibilityLabel(
            isTimelineSelectionMode ? "Finish selecting listening history entries" : "Select listening history entries"
        )
        updateTimelineSelectionControls()
        timelineTable.reloadData()
        layoutRegions()
    }

    func clearTimelineEntries() {
        timelineEntries.removeAll(keepingCapacity: true)
        timelineSelection.clear()
        timelineTable.deselectAll(nil)
        timelineTable.reloadData()
        timelineTableHeightConstraint?.constant = 0
        timelineEmptyLabel.isHidden = true
        selectTimelineButton.isHidden = true
        removeSelectedButton.isHidden = true
        selectTimelineButton.title = "Select"
    }

    func appendTimelineEntries(_ entries: [ListeningQualifiedPlayTimelineEntry]) {
        timelineEntries.append(contentsOf: entries)
        timelineTableHeightConstraint?.constant = CGFloat(timelineEntries.count) * timelineTable.rowHeight
        timelineTable.reloadData()
        timelineEmptyLabel.isHidden = !timelineEntries.isEmpty
        selectTimelineButton.isHidden = timelineEntries.isEmpty
        updateTimelineSelectionControls()
    }

    func updateTimelineSelectionControls() {
        let count = selectedTimelineEventIDs.count
        removeSelectedButton.title = "Remove Selected (\(count))"
        removeSelectedButton.setAccessibilityLabel(
            count == 1
                ? "Remove 1 selected listening history entry"
                : "Remove \(count) selected listening history entries"
        )
        removeSelectedButton.isHidden = count == 0
        removeSelectedButton.isEnabled = count > 0 && !statisticsModel.isResetInFlight
        selectTimelineButton.isEnabled = !statisticsModel.isResetInFlight
    }

    private func setTimelineEntry(_ eventID: UUID, selected: Bool) {
        guard isTimelineSelectionMode,
              timelineEntries.contains(where: { $0.eventID == eventID && $0.isFinalized }),
              !statisticsModel.isResetInFlight else { return }
        timelineSelection.setCheckboxSelection(selected, for: eventID)
        updateTimelineSelectionControls()
        timelineTable.reloadData()
    }
}
