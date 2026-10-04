import AppKit
import WavebookCore

extension StatisticsPageViewController {
    // MARK: Loading

    func refresh() {
    guard statisticsLoader.isActivePage else { return }
        if isViewLoaded { layoutRegions() }
        refreshStatusOnly()
        let year = statisticsModel.displayedYear
        let started = statisticsLoader.loadYear(year: year, databaseProvider: databaseProvider) { [weak self] result in
            guard let self else { return }
            self.setLoading(false)
            switch result {
            case .success(let snapshot):
                self.apply(snapshot)
            case .failure:
                self.showLoadError()
            }
        }
        guard started else {
            showEmptyState()
            return
        }
        setLoading(true)
        errorLabel.isHidden = true
        retryButton.isHidden = true
        errorRow.isHidden = true
    }

    private func apply(_ snapshot: StatisticsYearSnapshot) {
        let selectedDay = statisticsModel.selectedDay
        statisticsModel.setYearSnapshot(snapshot)
        updateNavigation()
        yearLabel.stringValue = String(snapshot.year)
        updateSummaryRows(snapshot)
        heatmapView.reload(days: snapshot.heatmap, selectedDay: selectedDay)
        for dimension in ListeningStatisticsDimension.allCases {
            updateRankingSection(dimension: dimension, entries: snapshot.rankings[dimension] ?? [])
        }
        updateSkippedSection(snapshot.skippedSongs)
        let lifetime = snapshot.lifetime
        if lifetime.qualifiedPlayCount == 0, lifetime.listenedSeconds == 0, lifetime.skipCount == 0 {
            showEmptyState()
            return
        }
        contentStack.isHidden = false
        emptyLabel.isHidden = true
        // Selected day belongs to the previously shown year; reset on change.
        if let selectedDay, selectedDay.year != snapshot.year {
            selectDay(nil)
        } else if selectedDay != nil {
            timelineStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            statisticsModel.setTimelineCursor(nil)
            refreshDayData()
            loadTimelinePage(cursor: nil)
        }
        layoutRegions()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func refreshStatusOnly() {
        guard isViewLoaded else { return }
        var lines: [String] = []
        if let tracker = trackerProvider(), tracker.isPrivateMode {
            lines.append("Private listening is on — new playback is not recorded.")
        }
        if let warning = trackerProvider()?.persistenceWarning {
            lines.append(warning)
        }
        statusLabel.stringValue = lines.joined(separator: "\n")
        resetButton.isEnabled = !statisticsModel.isResetInFlight && trackerProvider() != nil
        updateNavigation()
        layoutRegions()
    }

    private func updateNavigation() {
        let currentCalendarYear = Calendar.current.component(.year, from: Date())
        previousYearButton.isEnabled = statisticsModel.displayedYear > 1 && !statisticsModel.isResetInFlight
        nextYearButton.isEnabled = statisticsModel.displayedYear < currentCalendarYear
            && !statisticsModel.isResetInFlight
        retryButton.isEnabled = !statisticsModel.isResetInFlight
    }

    private func setLoading(_ loading: Bool) {
        loadingIndicator.isHidden = !loading
        if loading { loadingIndicator.startAnimation(nil) } else { loadingIndicator.stopAnimation(nil) }
    }

    private func showLoadError() {
        errorLabel.stringValue = "Could not load statistics. The last valid view is still shown."
        errorLabel.isHidden = false
        retryButton.isHidden = false
        errorRow.isHidden = false
        layoutRegions()
    }

    private func showEmptyState() {
        setLoading(false)
        errorLabel.isHidden = true
        retryButton.isHidden = true
        errorRow.isHidden = true
        emptyLabel.isHidden = false
        contentStack.isHidden = true
        if let startedAt = trackerProvider()?.trackingStartedAtUTC {
            emptyLabel.stringValue = "No listening history yet. Tracking started "
                + dateFormatter.string(from: startedAt)
        } else {
            emptyLabel.stringValue = "No listening history yet."
        }
        layoutRegions()
    }

    // MARK: Day selection and timeline

    func selectDay(_ day: ListeningLocalDay?) {
        guard statisticsModel.selectDay(day) else { return }
        statisticsLoader.cancelDayAndTimeline()
        timelineStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        heatmapView.reload(days: statisticsModel.yearSnapshot?.heatmap ?? [], selectedDay: day)
        guard let day else {
            dayTitleLabel.stringValue = ""
            daySummaryLabel.stringValue = ""
            dayTitleLabel.isHidden = true
            daySummaryLabel.isHidden = true
            timelineStack.isHidden = true
            loadMoreButton.isHidden = true
            // The day snapshot replaced these with day-scoped data; restore
            // the year view that was showing before selection.
            if let yearSnapshot = statisticsModel.yearSnapshot {
                for dimension in ListeningStatisticsDimension.allCases {
                    updateRankingSection(dimension: dimension, entries: yearSnapshot.rankings[dimension] ?? [])
                }
                updateSkippedSection(yearSnapshot.skippedSongs)
            }
            layoutRegions()
            return
        }
        dayTitleLabel.isHidden = false
        daySummaryLabel.isHidden = false
        timelineStack.isHidden = false
        dayTitleLabel.stringValue = dateFormatter.string(
            from: dateFor(day: day)
        )
        daySummaryLabel.stringValue = "Loading…"
        layoutRegions()
        refreshDayData()
        loadTimelinePage(cursor: nil)
    }

    private func refreshDayData() {
        guard statisticsLoader.isActivePage, let day = statisticsModel.selectedDay else { return }
        let started = statisticsLoader.loadDay(day: day, databaseProvider: databaseProvider) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.daySummaryLabel.stringValue = "Could not load day statistics."
                self.errorLabel.stringValue = "Could not load statistics for this day."
                self.errorLabel.isHidden = false
                self.retryButton.isHidden = false
                self.errorRow.isHidden = false
                self.layoutRegions()
            case .success(let snapshot):
                self.daySummaryLabel.stringValue = Self.summaryLine(snapshot.summary)
                for dimension in ListeningStatisticsDimension.allCases {
                    self.updateRankingSection(
                        dimension: dimension,
                        entries: snapshot.rankings[dimension] ?? [],
                        dayScope: true
                    )
                }
                self.updateSkippedSection(snapshot.skippedSongs, dayScope: true)
                self.layoutRegions()
            }
        }
        guard started else { return }
    }

    func loadTimelinePage(cursor: ListeningTimelineCursor?) {
        guard statisticsLoader.isActivePage, let day = statisticsModel.selectedDay else { return }
        let started = statisticsLoader.loadTimelinePage(
            day: day,
            cursor: cursor,
            databaseProvider: databaseProvider
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                // Keep already-loaded rows; Load More doubles as retry.
                self.showTimelineFailureNote()
                self.loadMoreButton.isHidden = false
                self.layoutRegions()
            case .success(let page):
                self.removeTimelineFailureNote()
                self.statisticsModel.setTimelineCursor(page.nextCursor)
                for entry in page.entries {
                    self.timelineStack.addArrangedSubview(self.timelineRow(entry))
                }
                if page.entries.isEmpty, cursor == nil {
                    let none = NSTextField(labelWithString: "No qualified plays this day.")
                    none.font = .systemFont(ofSize: 12)
                    none.textColor = AppTheme.secondaryText
                    self.timelineStack.addArrangedSubview(none)
                }
                self.loadMoreButton.isHidden = page.nextCursor == nil
                self.layoutRegions()
            }
        }
        guard started else { return }
        loadMoreButton.isHidden = true
    }

    private func showTimelineFailureNote() {
        removeTimelineFailureNote()
        let note = NSTextField(labelWithString: "Could not load more timeline entries.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .systemRed
        timelineFailureNote = note
        timelineStack.addArrangedSubview(note)
    }

    private func removeTimelineFailureNote() {
        timelineFailureNote?.removeFromSuperview()
        timelineFailureNote = nil
    }

    private func timelineRow(_ entry: ListeningQualifiedPlayTimelineEntry) -> NSView {
        timeFormatter.timeZone = TimeZone(secondsFromGMT: entry.utcOffsetSeconds)
        let row = NSTextField(labelWithString: "\(timeFormatter.string(from: entry.qualifiedAtUTC)) — "
            + "\(entry.title) · \(entry.artistDisplay) · \(entry.albumTitle)")
        row.font = .systemFont(ofSize: 12)
        row.textColor = AppTheme.primaryText
        row.lineBreakMode = .byTruncatingTail
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func dateFor(day: ListeningLocalDay) -> Date {
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }
}
