import AppKit

extension StatisticsPageViewController {
    // MARK: Actions

    @objc func previousYearClicked() {
        statisticsModel.moveYear(by: -1)
        selectDay(nil)
        refresh()
    }

    @objc func nextYearClicked() {
        statisticsModel.moveYear(by: 1)
        selectDay(nil)
        refresh()
    }

    @objc func retryClicked() {
        refresh()
    }

    @objc func loadMoreClicked() {
        loadTimelinePage(cursor: statisticsModel.timelineCursor)
    }
}
