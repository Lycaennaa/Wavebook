import AppKit
import WavebookCore

private final class StatisticsRootView: ThemeBackgroundView {
    override var isFlipped: Bool { true }
}
// UI construction and section rendering for the statistics page.
struct StatisticsSkippedSection {
    let title: NSTextField
    let rows: NSStackView
    let empty: NSTextField
}

extension StatisticsPageViewController {
    // MARK: Section builders

    func buildContentSections() {

        let summaryGrid = NSStackView(views: [
            makeSummaryColumn(title: "This Year"),
            makeSummaryColumn(title: "Lifetime")
        ])
        summaryGrid.orientation = .horizontal
        summaryGrid.spacing = 40
        contentStack.addArrangedSubview(sectionTitle("Overview"))
        contentStack.addArrangedSubview(summaryGrid)

        heatmapView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(sectionTitle("Plays per Day"))
        contentStack.addArrangedSubview(heatmapView)
        contentStack.addArrangedSubview(focusInfoLabel)

        contentStack.addArrangedSubview(dayTitleLabel)
        contentStack.addArrangedSubview(daySummaryLabel)
        contentStack.addArrangedSubview(timelineStack)
        contentStack.addArrangedSubview(loadMoreButton)

        for dimension in ListeningStatisticsDimension.allCases {
            let section = makeRankingSection(dimension: dimension)
            rankingSections[dimension] = section
            contentStack.addArrangedSubview(sectionTitle(Self.rankingTitle(dimension)))
            contentStack.addArrangedSubview(section)
        }
        let skipped = makeSkippedSection()
        skippedSection = skipped
        contentStack.addArrangedSubview(skipped.title)
        contentStack.addArrangedSubview(skipped.rows)
        contentStack.addArrangedSubview(skipped.empty)
    }
    override func loadView() {
        let root = StatisticsRootView()
        configureNavigationButtons()
        configureLabelsAndActions()
        configureContentStack()
        configureScrollView()
        configureHeader()
        configureErrorRow()
        root.addSubview(headerStack)
        root.addSubview(errorRow)
        root.addSubview(emptyLabel)
        root.addSubview(scrollView)
        view = root
    }

    private func configureNavigationButtons() {
        for button in [previousYearButton, nextYearButton] {
            button.bezelStyle = .texturedRounded
            button.contentTintColor = AppTheme.accent
            button.target = self
        }
        previousYearButton.action = #selector(previousYearClicked)
        nextYearButton.action = #selector(nextYearClicked)
        previousYearButton.setAccessibilityLabel("Previous Year")
        nextYearButton.setAccessibilityLabel("Next Year")
        resetButton.bezelStyle = .rounded
        resetButton.contentTintColor = .systemRed
        resetButton.target = self
        resetButton.action = #selector(resetClicked)
        resetButton.setAccessibilityLabel("Reset listening history")
        loadMoreButton.bezelStyle = .rounded
        loadMoreButton.contentTintColor = AppTheme.accent
        loadMoreButton.target = self
        loadMoreButton.action = #selector(loadMoreClicked)
        loadMoreButton.isHidden = true
    }

    private func configureLabelsAndActions() {
        yearLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        yearLabel.textColor = AppTheme.primaryText
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = AppTheme.secondaryText
        statusLabel.setAccessibilityLabel("Statistics status")
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = AppTheme.secondaryText
        emptyLabel.isHidden = true
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.isHidden = true
        errorRow.isHidden = true
        loadingIndicator.isIndeterminate = true
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        focusInfoLabel.font = .systemFont(ofSize: 11)
        focusInfoLabel.textColor = AppTheme.secondaryText
        heatmapView.onSelectDay = { [weak self] day in self?.selectDay(day) }
        heatmapView.onFocusChanged = { [weak self] entry in
            self?.focusInfoLabel.stringValue = Self.focusDescription(entry)
        }
        dayTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        dayTitleLabel.textColor = AppTheme.primaryText
        daySummaryLabel.font = .systemFont(ofSize: 12)
        daySummaryLabel.textColor = AppTheme.secondaryText
        timelineStack.orientation = .vertical
        timelineStack.alignment = .leading
        timelineStack.spacing = 3
    }

    private func configureContentStack() {
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 18, right: 18)
        buildContentSections()
    }

    private func configureScrollView() {
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.drawsBackground = false
        scrollView.documentView = contentStack
    }

    private func configureHeader() {
        [
            previousYearButton, yearLabel, nextYearButton, loadingIndicator, statusLabel, NSView(), resetButton
        ].forEach { headerStack.addArrangedSubview($0) }
        headerStack.orientation = .horizontal
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = true
    }

    private func configureErrorRow() {
        errorRow.addArrangedSubview(errorLabel)
        errorRow.addArrangedSubview(retryButton)
        errorRow.orientation = .horizontal
        errorRow.spacing = 8
        errorRow.translatesAutoresizingMaskIntoConstraints = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutRegions()
    }

    func layoutRegions() {
        guard isViewLoaded, !isLayingOutRegions else { return }
        isLayingOutRegions = true
        defer { isLayingOutRegions = false }

        let width = view.bounds.width
        let height = view.bounds.height
        let horizontalInset: CGFloat = 18
        var headerHeight: CGFloat = 32
        headerStack.frame = NSRect(
            x: horizontalInset,
            y: 14,
            width: max(0, width - horizontalInset * 2),
            height: headerHeight
        )
        headerStack.layoutSubtreeIfNeeded()
        headerHeight = max(headerHeight, headerStack.fittingSize.height)
        headerStack.frame.size.height = headerHeight
        headerStack.layoutSubtreeIfNeeded()

        var bodyTop = headerStack.frame.maxY + 6
        if !errorRow.isHidden {
            let errorHeight = max(24, errorLabel.fittingSize.height)
            errorRow.frame = NSRect(
                x: horizontalInset,
                y: bodyTop,
                width: max(0, width - horizontalInset * 2),
                height: errorHeight
            )
            errorRow.layoutSubtreeIfNeeded()
            bodyTop = errorRow.frame.maxY + 6
        } else {
            errorRow.frame = .zero
        }

        if emptyLabel.isHidden {
            scrollView.isHidden = false
            scrollView.frame = NSRect(
                x: 0,
                y: bodyTop,
                width: width,
                height: max(0, height - bodyTop)
            )
            layoutScrollContent()
        } else {
            scrollView.isHidden = true
            emptyLabel.frame = NSRect(
                x: horizontalInset,
                y: bodyTop,
                width: max(0, width - horizontalInset * 2),
                height: 32
            )
        }
    }

    private func layoutScrollContent() {
        let contentSize = scrollView.contentView.bounds.size
        contentStack.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: 0)
        contentStack.layoutSubtreeIfNeeded()
        contentStack.frame.size = NSSize(
            width: contentSize.width,
            height: max(contentSize.height, contentStack.fittingSize.height)
        )
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = AppTheme.primaryText
        return label
    }

    private func bodyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = AppTheme.secondaryText
        return label
    }

    private func makeSummaryColumn(title: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.addArrangedSubview(bodyLabel(title))
        let rows = (0..<2).map { _ -> NSTextField in
            let row = NSTextField(labelWithString: "—")
            row.font = .systemFont(ofSize: 12)
            row.textColor = AppTheme.primaryText
            stack.addArrangedSubview(row)
            return row
        }
        summaryColumnLabels.append(rows)
        return stack
    }

    func updateSummaryRows(_ snapshot: StatisticsYearSnapshot) {
        let renderData = ListeningStatisticsSummaryRenderData(
            year: snapshot.summary,
            lifetime: snapshot.lifetime
        )
        guard summaryColumnLabels.count == renderData.columns.count else { return }
        for (labels, rows) in zip(summaryColumnLabels, renderData.columns) {
            guard labels.count == rows.count else { return }
            for (label, row) in zip(labels, rows) {
                label.stringValue = Self.summaryLine(row)
            }
        }
    }

    private static func summaryLine(_ row: ListeningStatisticsSummaryRenderRow) -> String {
        switch row {
        case let .playsAndTime(qualifiedPlayCount, listenedSeconds):
            return "\(qualifiedPlayCount) plays · \(duration(listenedSeconds))"
        case let .songsArtistsAndSkips(uniqueSongCount, uniqueArtistCount, skipCount):
            return "\(uniqueSongCount) songs · \(uniqueArtistCount) artists · \(skipCount) skips"
        }
    }

    private func makeRankingSection(dimension: ListeningStatisticsDimension) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        for index in 0..<10 {
            let row = NSTextField(labelWithString: "")
            row.font = .systemFont(ofSize: 12)
            row.textColor = AppTheme.primaryText
            row.lineBreakMode = .byTruncatingTail
            row.tag = index + 1
            row.isHidden = true
            stack.addArrangedSubview(row)
        }
        return stack
    }

    func updateRankingSection(
        dimension: ListeningStatisticsDimension,
        entries: [ListeningRankingEntry],
        dayScope: Bool = false
    ) {
        guard let section = rankingSections[dimension] else { return }
        for (index, row) in section.arrangedSubviews.compactMap({ $0 as? NSTextField }).enumerated() {
            if index < entries.count {
                let entry = entries[index]
                row.stringValue = "\(index + 1). \(entry.displayName) — "
                    + "\(entry.qualifiedPlayCount) plays · \(Self.duration(entry.listenedSeconds))"
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
    }

    private func makeSkippedSection() -> StatisticsSkippedSection {
        let title = sectionTitle("Top Skipped Songs")
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 3
        for _ in 0..<10 {
            let row = NSTextField(labelWithString: "")
            row.font = .systemFont(ofSize: 12)
            row.textColor = AppTheme.primaryText
            row.lineBreakMode = .byTruncatingTail
            row.isHidden = true
            rows.addArrangedSubview(row)
        }
        let empty = bodyLabel("No skips recorded.")
        empty.isHidden = true
        return StatisticsSkippedSection(title: title, rows: rows, empty: empty)
    }

    func updateSkippedSection(_ entries: [ListeningSkippedSong], dayScope: Bool = false) {
        guard let section = skippedSection else { return }
        let rows = section.rows.arrangedSubviews.compactMap { $0 as? NSTextField }
        for (index, row) in rows.enumerated() {
            if index < entries.count {
                let entry = entries[index]
                row.stringValue = "\(index + 1). \(entry.title) · \(entry.artistDisplay) — "
                    + "\(entry.skipCount) skips"
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
        section.empty.isHidden = !entries.isEmpty
    }

    // MARK: Formatting helpers

    static func rankingTitle(_ dimension: ListeningStatisticsDimension) -> String {
        switch dimension {
        case .song: return "Top Songs"
        case .album: return "Top Albums"
        case .artist: return "Top Artists"
        case .genre: return "Top Genres"
        }
    }

    static func summaryLine(_ summary: ListeningStatisticsSummary) -> String {
        "\(summary.qualifiedPlayCount) qualified plays · \(duration(summary.listenedSeconds)) listened"
            + " · \(summary.skipCount) skips"
    }

    static func focusDescription(_ entry: ListeningHeatmapDay?) -> String {
        guard let entry else { return "" }
        let count = entry.qualifiedPlayCount == 1 ? "1 qualified play" : "\(entry.qualifiedPlayCount) qualified plays"
        return entry.day.rawValue + " — " + count
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0m" }
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes >= 60 {
            return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
        }
        return "\(totalMinutes)m"
    }
}
