import AppKit
import WavebookCore

// GitHub-style fixed sunday-start year heatmap. At most 366 cells; each cell
// carries an exact-count tooltip/accessibility label so color never carries
// the play count alone.
final class StatisticsHeatmapView: NSView, NSViewToolTipOwner {
    var onSelectDay: ((ListeningLocalDay?) -> Void)?
    var onFocusChanged: ((ListeningHeatmapDay?) -> Void)?

    private struct Cell {
        let rect: NSRect
        let entry: ListeningHeatmapDay
        let dayIndex: Int
    }

    private static let pitch: CGFloat = 15
    private static let cellSize: CGFloat = 12
    private static let topInset: CGFloat = 18
    private static let leftInset: CGFloat = 2
    private var days: [ListeningHeatmapDay] = []
    private var cells: [Cell] = []
    private var firstVisibleDayIndex = 0
    private struct MonthLabel {
        let text: String
        let point: NSPoint
    }

    private var fillPaths: [ListeningHeatmapBucket: NSBezierPath] = [:]
    private var monthLabels: [MonthLabel] = []
    private var tooltipLabels: [NSView.ToolTipTag: String] = [:]
    private(set) var selectedDay: ListeningLocalDay?
    private var focusIndex: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { !cells.isEmpty }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.leftInset + CGFloat(gridMetrics().columns) * Self.pitch,
               height: Self.topInset + 7 * Self.pitch)
    }

    // MARK: Data

    static func visibleStartIndex(in days: [ListeningHeatmapDay]) -> Int {
        days.firstIndex(where: { $0.qualifiedPlayCount > 0 }) ?? days.count
    }

    func reload(days: [ListeningHeatmapDay], selectedDay: ListeningLocalDay?) {
        self.days = days
        self.selectedDay = selectedDay
        firstVisibleDayIndex = Self.visibleStartIndex(in: days)
        if let selectedDay,
           let index = days.firstIndex(where: { $0.day == selectedDay }),
           index >= firstVisibleDayIndex {
            focusIndex = index
        } else if focusIndex.map({ $0 < firstVisibleDayIndex || !days.indices.contains($0) }) == true {
            focusIndex = firstVisibleDayIndex < days.count ? firstVisibleDayIndex : nil
        }
        layoutCells()
        invalidateIntrinsicContentSize()
        notifyFocusChanged()
    }
    private func layoutCells() {
        removeAllToolTips()
        tooltipLabels.removeAll(keepingCapacity: true)
        cells.removeAll(keepingCapacity: true)
        fillPaths.removeAll(keepingCapacity: true)
        monthLabels.removeAll(keepingCapacity: true)
        guard !days.isEmpty else {
            needsDisplay = true
            return
        }
        let metrics = gridMetrics()
        var lastLabeledColumn = -3
        for (index, entry) in days.enumerated() {
            guard index >= firstVisibleDayIndex else { continue }
            let slot = index + metrics.leadingBlanks - metrics.firstVisibleColumn * 7
            let rect = NSRect(
                x: Self.leftInset + CGFloat(slot / 7) * Self.pitch,
                y: Self.topInset + CGFloat(slot % 7) * Self.pitch,
                width: Self.cellSize,
                height: Self.cellSize
            )
            cells.append(Cell(rect: rect, entry: entry, dayIndex: index))
            let fillPath = fillPaths[entry.bucket] ?? NSBezierPath()
            fillPath.appendRoundedRect(rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
            fillPaths[entry.bucket] = fillPath
            let tooltipTag = addToolTip(rect, owner: self, userData: nil)
            tooltipLabels[tooltipTag] = label(for: entry)
            guard entry.day.day == 1 || index == firstVisibleDayIndex else { continue }
            let column = (Int(rect.minX) - Int(Self.leftInset)) / Int(Self.pitch)
            guard column - lastLabeledColumn >= 2 else { continue }
            lastLabeledColumn = column
            monthLabels.append(
                MonthLabel(
                    text: monthFormatter.string(
                        from: calendarDate(year: entry.day.year, month: entry.day.month, day: 1)
                    ),
                    point: NSPoint(x: rect.minX, y: 4)
                )
            )
        }
        needsDisplay = true
    }

    private struct GridMetrics {
        let leadingBlanks: Int
        let firstVisibleColumn: Int
        let columns: Int
    }

    static func visibleGridMetrics(
        dayCount: Int,
        firstVisibleDayIndex: Int,
        leadingBlanks: Int
    ) -> (firstVisibleColumn: Int, columns: Int) {
        guard firstVisibleDayIndex < dayCount else { return (0, 0) }
        let firstVisibleColumn = (firstVisibleDayIndex + leadingBlanks) / 7
        let totalColumns = (dayCount + leadingBlanks + 6) / 7
        return (firstVisibleColumn, totalColumns - firstVisibleColumn)
    }

    private func gridMetrics() -> GridMetrics {
        guard let first = days.first else {
            return GridMetrics(leadingBlanks: 0, firstVisibleColumn: 0, columns: 0)
        }
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = first.day.year
        components.month = 1
        components.day = 1
        guard let januaryFirst = calendar.date(from: components) else {
            return GridMetrics(leadingBlanks: 0, firstVisibleColumn: 0, columns: 0)
        }
        let leadingBlanks = calendar.component(.weekday, from: januaryFirst) - 1
        let visibleMetrics = Self.visibleGridMetrics(
            dayCount: days.count,
            firstVisibleDayIndex: firstVisibleDayIndex,
            leadingBlanks: leadingBlanks
        )
        return GridMetrics(
            leadingBlanks: leadingBlanks,
            firstVisibleColumn: visibleMetrics.firstVisibleColumn,
            columns: visibleMetrics.columns
        )
    }

    // MARK: Drawing

    private lazy var monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()

    private lazy var dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM y")
        return formatter
    }()

    private func calendarDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !cells.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: AppTheme.secondaryText
        ]
        for month in monthLabels {
            month.text.draw(at: month.point, withAttributes: attributes)
        }

        for (bucket, path) in fillPaths {
            fill(for: bucket).setFill()
            path.fill()
        }
        for cell in cells {
            let rect = cell.rect.insetBy(dx: 0.5, dy: 0.5)
            if cell.entry.day == selectedDay {
                AppTheme.primaryText.setStroke()
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3)
                path.lineWidth = 1.5
                path.stroke()
            }
            if cell.dayIndex == focusIndex, window?.firstResponder === self {
                AppTheme.accent.setStroke()
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 3.5, yRadius: 3.5)
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }

    private func fill(for bucket: ListeningHeatmapBucket) -> NSColor {
        switch bucket {
        case .zero: return AppTheme.raised
        case .one: return AppTheme.accent.withAlphaComponent(0.25)
        case .twoToThree: return AppTheme.accent.withAlphaComponent(0.45)
        case .fourToSeven: return AppTheme.accent.withAlphaComponent(0.7)
        case .eightOrMore: return AppTheme.accent
        }
    }

    private func label(for entry: ListeningHeatmapDay) -> String {
        let date = calendarDate(year: entry.day.year, month: entry.day.month, day: entry.day.day)
        let count = entry.qualifiedPlayCount == 1 ? "1 qualified play" : "\(entry.qualifiedPlayCount) qualified plays"
        return "\(dayFormatter.string(from: date)): \(count)"
    }

    // MARK: Mouse and keyboard interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = cells.first(where: { $0.rect.contains(point) }) else { return }
        window?.makeFirstResponder(self)
        select(index: cell.dayIndex)
    }

    private func select(index: Int) {
        guard days.indices.contains(index), index >= firstVisibleDayIndex else { return }
        focusIndex = index
        let day = days[index].day
        selectedDay = selectedDay == day ? nil : day
        needsDisplay = true
        notifyFocusChanged()
        onSelectDay?(selectedDay)
    }

    override func keyDown(with event: NSEvent) {
        guard let index = focusIndex, firstVisibleDayIndex < days.count else {
            interpretKeyEvents([event])
            return
        }
        if [36, 49, 76].contains(event.keyCode) {
            select(index: index)
            return
        }
        guard moveFocus(for: event.specialKey, from: index) else {
            interpretKeyEvents([event])
            return
        }
    }

    private func moveFocus(for specialKey: NSEvent.SpecialKey?, from index: Int) -> Bool {
        let target: Int
        switch specialKey {
        case .leftArrow: target = max(index - 1, firstVisibleDayIndex)
        case .rightArrow: target = min(index + 1, days.count - 1)
        case .upArrow: target = max(index - 7, firstVisibleDayIndex)
        case .downArrow: target = min(index + 7, days.count - 1)
        case .pageUp: target = max(index - 28 * 7, firstVisibleDayIndex)
        case .pageDown: target = min(index + 28 * 7, days.count - 1)
        case .home: target = firstVisibleDayIndex
        case .end: target = days.count - 1
        case .enter:
            select(index: index)
            return true
        default:
            return false
        }
        focusIndex = target
        needsDisplay = true
        notifyFocusChanged()
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        return true
    }

    override func becomeFirstResponder() -> Bool {
        if firstVisibleDayIndex < days.count,
           focusIndex.map({ $0 >= firstVisibleDayIndex }) != true {
            focusIndex = days.count - 1
        }
        needsDisplay = true
        notifyFocusChanged()
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    private func notifyFocusChanged() {
        onFocusChanged?(focusIndex.flatMap { days.indices.contains($0) ? days[$0] : nil })
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        tooltipLabels[tag] ?? ""
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        guard let window else { return nil }
        return cells.map { cell in
            NSAccessibilityElement.element(
                withRole: .cell,
                frame: window.convertToScreen(convert(cell.rect, to: nil)),
                label: label(for: cell.entry),
                parent: self
            )
        }
    }
}
