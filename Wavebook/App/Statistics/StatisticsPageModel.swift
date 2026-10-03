import Foundation
import WavebookCore

struct StatisticsYearSnapshot: Sendable {
    let year: Int
    let summary: ListeningStatisticsSummary
    let lifetime: ListeningStatisticsSummary
    let heatmap: [ListeningHeatmapDay]
    let rankings: [ListeningStatisticsDimension: [ListeningRankingEntry]]
    let skippedSongs: [ListeningSkippedSong]
}

struct StatisticsDaySnapshot: Sendable {
    let day: ListeningLocalDay
    let summary: ListeningStatisticsSummary
    let rankings: [ListeningStatisticsDimension: [ListeningRankingEntry]]
    let skippedSongs: [ListeningSkippedSong]
}

struct StatisticsPageModel {
    private(set) var displayedYear: Int
    private(set) var yearSnapshot: StatisticsYearSnapshot?
    private(set) var selectedDay: ListeningLocalDay?
    private(set) var timelineCursor: ListeningTimelineCursor?
    private(set) var isResetInFlight = false

    init(displayedYear: Int = Calendar.current.component(.year, from: Date())) {
        self.displayedYear = displayedYear
    }

    mutating func moveYear(by offset: Int) {
        displayedYear += offset
    }

    mutating func setYearSnapshot(_ snapshot: StatisticsYearSnapshot) {
        yearSnapshot = snapshot
    }

    mutating func selectDay(_ day: ListeningLocalDay?) -> Bool {
        guard day != selectedDay else { return false }
        selectedDay = day
        timelineCursor = nil
        return true
    }

    mutating func setTimelineCursor(_ cursor: ListeningTimelineCursor?) {
        timelineCursor = cursor
    }

    mutating func beginReset() -> Bool {
        guard !isResetInFlight else { return false }
        isResetInFlight = true
        return true
    }

    mutating func finishReset() {
        isResetInFlight = false
    }
}
