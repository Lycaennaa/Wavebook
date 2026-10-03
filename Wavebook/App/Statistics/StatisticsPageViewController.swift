import AppKit
import WavebookCore

// Statistics page (phase 5). Bounded loading only: one year snapshot
// (<= 366 heatmap cells, <= 10 ranking rows per dimension) and cursor-paged
// day timelines of 100 rows. Stale loads are rejected via generation tokens.

final class StatisticsContentStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class StatisticsPageViewController: NSViewController {
    var databaseProvider: () -> LibraryDatabase? = { nil }
    var trackerProvider: () -> ListeningHistoryTracker? = { nil }
    // Live playback state so resetHistory restarts at the actual rendered
    // position instead of a stale context captured by the tracker.
    var renderedPositionProvider: () -> TimeInterval? = { nil }
    var isPlayingProvider: () -> Bool = { false }

    // MARK: State

    var statisticsModel = StatisticsPageModel()
    let statisticsLoader = StatisticsPageLoader()
    var timelineFailureNote: NSTextField?
    var isLayingOutRegions = false

    func activate() {
        statisticsLoader.activate()
    }

    func deactivate() {
        statisticsLoader.deactivate()
    }

    // MARK: Views

    let previousYearButton = NSButton(title: "‹", target: nil, action: nil)
    let nextYearButton = NSButton(title: "›", target: nil, action: nil)
    let yearLabel = NSTextField(labelWithString: "")
    let resetButton = NSButton(title: "Reset History…", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let emptyLabel = NSTextField(wrappingLabelWithString: "")
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let errorRow = NSStackView()
    let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    let loadingIndicator = NSProgressIndicator()
    let scrollView = NSScrollView()
    let headerStack = NSStackView()
    let contentStack = StatisticsContentStackView()
    let heatmapView = StatisticsHeatmapView()
    let focusInfoLabel = NSTextField(labelWithString: "")
    let dayTitleLabel = NSTextField(labelWithString: "")
    let daySummaryLabel = NSTextField(wrappingLabelWithString: "")
    let timelineStack = NSStackView()
    let loadMoreButton = NSButton(title: "Load More", target: nil, action: nil)
    var summaryColumnLabels: [[NSTextField]] = []
    var rankingSections: [ListeningStatisticsDimension: NSStackView] = [:]
    var skippedSection: StatisticsSkippedSection?
    lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
    lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        activate()
        // onPersistenceWarningChanged is owned by MainViewController, which
        // routes updates to refreshStatusOnly(); reassigning it here would
        // drop the persistence banner handling.
        refresh()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        deactivate()
        // Leaving the page may reset the selected day; keep the year.
        selectDay(nil)
        refreshStatusOnly()
    }

}
extension StatisticsPageViewController: NavigationHost {
    var page: LibraryPage { .statistics }
    var selectedTrack: Track? { nil }
    var tracks: [Track] { [] }
}
