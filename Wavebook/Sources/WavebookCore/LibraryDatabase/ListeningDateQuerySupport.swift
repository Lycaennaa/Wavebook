import Foundation
import GRDB
struct ListeningDateRange {
    let start: Double
    let endExclusive: Double
}
extension LibraryDatabase {
    static func currentTimeZoneDateRange(
        from startDay: ListeningLocalDay,
        through endDay: ListeningLocalDay
    ) -> ListeningDateRange? {
        guard startDay <= endDay else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let startInterval = currentTimeZoneDayInterval(startDay, calendar: calendar),
              let endInterval = currentTimeZoneDayInterval(endDay, calendar: calendar) else {
            return nil
        }
        let start = startInterval.start.timeIntervalSinceReferenceDate
        let endExclusive = endInterval.end.timeIntervalSinceReferenceDate
        guard start.isFinite, endExclusive.isFinite, start < endExclusive else { return nil }
        return ListeningDateRange(start: start, endExclusive: endExclusive)
    }

    private static func currentTimeZoneDayInterval(
        _ day: ListeningLocalDay,
        calendar: Calendar
    ) -> DateInterval? {
        let noonComponents = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: day.year,
            month: day.month,
            day: day.day,
            hour: 12
        )
        guard let noon = calendar.date(from: noonComponents) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: noon)
        guard components.year == day.year,
              components.month == day.month,
              components.day == day.day else {
            return nil
        }
        return calendar.dateInterval(of: .day, for: noon)
    }

    static func currentTimeZoneDateRange(for day: ListeningLocalDay) -> ListeningDateRange? {
        currentTimeZoneDateRange(from: day, through: day)
    }
    static func validateListeningScope(year: Int?, day: ListeningLocalDay?) throws {
        if let year, !(0...9999).contains(year) {
            throw LibraryDatabaseError.invalidListeningYear(year)
        }
        if let day, let year, day.year != year {
            throw LibraryDatabaseError.invalidListeningDay(day.rawValue)
        }
    }

    static func listeningYearStart(_ year: Int) throws -> ListeningLocalDay {
        try validateListeningScope(year: year, day: nil)
        guard let day = ListeningLocalDay(year: year, month: 1, day: 1) else {
            throw LibraryDatabaseError.invalidListeningYear(year)
        }
        return day
    }

    static func listeningYearEnd(_ year: Int) throws -> ListeningLocalDay {
        try validateListeningScope(year: year, day: nil)
        guard let day = ListeningLocalDay(year: year, month: 12, day: 31) else {
            throw LibraryDatabaseError.invalidListeningYear(year)
        }
        return day
    }
    static func listeningScopePredicate(
        column: String,
        year: Int?,
        day: ListeningLocalDay?,
        arguments: inout StatementArguments
    ) throws -> String {
        guard year != nil || day != nil else { return "1 = 1" }
        let startDay: ListeningLocalDay
        let endDay: ListeningLocalDay
        if let day {
            startDay = day
            endDay = day
        } else if let year,
                  let yearStart = ListeningLocalDay(year: year, month: 1, day: 1),
                  let yearEnd = ListeningLocalDay(year: year, month: 12, day: 31) {
            startDay = yearStart
            endDay = yearEnd
        } else {
            throw LibraryDatabaseError.invalidListeningYear(year ?? 0)
        }
        guard let range = Self.currentTimeZoneDateRange(from: startDay, through: endDay) else {
            throw LibraryDatabaseError.invalidListeningDay(startDay.rawValue)
        }
        arguments += [range.start, range.endExclusive]
        return "\(column) >= ? AND \(column) < ?"
    }
}
