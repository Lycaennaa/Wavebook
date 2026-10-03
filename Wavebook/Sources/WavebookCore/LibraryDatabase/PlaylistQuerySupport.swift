import Foundation
import GRDB

struct PlaylistSQLCompilation {
    let clause: String
    let arguments: StatementArguments
}

enum PlaylistSQLFunctions {
    static let normalizedContains = DatabaseFunction(
        "wavebook_normalized_contains",
        argumentCount: 2,
        pure: true
    ) { values in
        guard let haystack = String.fromDatabaseValue(values[0]),
              let needle = String.fromDatabaseValue(values[1]) else {
            return 0
        }
        return SearchNormalizer.normalizedText(haystack)
            .contains(SearchNormalizer.normalizedText(needle)) ? 1 : 0
    }

    static func install(in database: Database) {
        database.add(function: normalizedContains)
    }
}

private struct PlaylistDateClause {
    let field: PlaylistRuleField
    let operation: PlaylistRuleOperator
    let start: ListeningLocalDay
    let end: ListeningLocalDay
    let trackAlias: String
    let historyAlias: String
}

enum PlaylistRuleCompiler {
    static func compile(
        _ rules: [PlaylistRule],
        trackAlias: String = "tracks",
        historyAlias: String = "playlistHistory"
    ) throws -> PlaylistSQLCompilation {
        try compile(
            PlaylistRuleValidator.validatedRules(rules),
            trackAlias: trackAlias,
            historyAlias: historyAlias
        )
    }

    static func compile(
        rulesJSON: String,
        trackAlias: String = "tracks",
        historyAlias: String = "playlistHistory"
    ) throws -> PlaylistSQLCompilation {
        try compile(
            PlaylistRuleValidator.validatedRules(from: rulesJSON),
            trackAlias: trackAlias,
            historyAlias: historyAlias
        )
    }

    private static func compile(
        _ rules: [ValidatedPlaylistRule],
        trackAlias: String,
        historyAlias: String
    ) throws -> PlaylistSQLCompilation {
        var arguments = StatementArguments()
        let clauses = try rules.map {
            try compile(
                $0,
                trackAlias: trackAlias,
                historyAlias: historyAlias,
                arguments: &arguments
            )
        }
        return PlaylistSQLCompilation(
            clause: clauses.isEmpty ? "1 = 1" : clauses.map { "(\($0))" }.joined(separator: " AND "),
            arguments: arguments
        )
    }

    private static func compile(
        _ rule: ValidatedPlaylistRule,
        trackAlias: String,
        historyAlias: String,
        arguments: inout StatementArguments
    ) throws -> String {
        switch rule.field {
        case .title, .artist, .album, .genre, .format:
            return try compileTextRule(rule, trackAlias: trackAlias, arguments: &arguments)
        case .duration, .qualifiedPlayCount:
            return try compileNumericRule(
                rule,
                trackAlias: trackAlias,
                historyAlias: historyAlias,
                arguments: &arguments
            )
        case .firstSeen, .lastQualifiedPlayDate, .qualifiedPlayDate:
            return try compileDateRule(rule, trackAlias: trackAlias, historyAlias: historyAlias, arguments: &arguments)
        }
    }

    private static func compileTextRule(
        _ rule: ValidatedPlaylistRule,
        trackAlias: String,
        arguments: inout StatementArguments
    ) throws -> String {
        let expression = textExpression(rule.field, alias: trackAlias)
        switch rule.operation {
        case .contains:
            guard case let .text(value) = rule.value else {
                throw invalidRule("text rule has no value")
            }
            arguments += [value]
            return "wavebook_normalized_contains(\(expression), ?) = 1"
        case .isEmpty:
            return "COALESCE(trim(\(expression)), '') = ''"
        case .isNotEmpty:
            return "COALESCE(trim(\(expression)), '') <> ''"
        default:
            throw invalidRule("operator is not supported for text")
        }
    }

    private static func compileNumericRule(
        _ rule: ValidatedPlaylistRule,
        trackAlias: String,
        historyAlias: String,
        arguments: inout StatementArguments
    ) throws -> String {
        guard case let .number(number) = rule.value else {
            throw invalidRule("numeric rule has no value")
        }
        let expression = rule.field == .duration
            ? "\(trackAlias).duration"
            : "COALESCE(\(historyAlias).qualifiedPlayCount, 0)"
        arguments += [number]
        switch rule.operation {
        case .greaterThan: return "\(expression) > ?"
        case .lessThan: return "\(expression) < ?"
        default: throw invalidRule("operator is not supported for numeric fields")
        }
    }

    private static func compileDateRule(
        _ rule: ValidatedPlaylistRule,
        trackAlias: String,
        historyAlias: String,
        arguments: inout StatementArguments
    ) throws -> String {
        switch rule.operation {
        case .isEmpty:
            return emptyDateClause(rule.field, historyAlias: historyAlias)
        case .isNotEmpty:
            return nonemptyDateClause(rule.field, historyAlias: historyAlias)
        case .onOrAfter, .onOrBefore, .between:
            guard case let .dateRange(start, end) = rule.value else {
                throw invalidRule("date rule has no value")
            }
            return try dateClause(
                PlaylistDateClause(
                    field: rule.field,
                    operation: rule.operation,
                    start: start,
                    end: end,
                    trackAlias: trackAlias,
                    historyAlias: historyAlias
                ),
                arguments: &arguments
            )
        default:
            throw invalidRule("operator is not supported for dates")
        }
    }

    private static func textExpression(_ field: PlaylistRuleField, alias: String) -> String {
        switch field {
        case .title: return "\(alias).title"
        case .artist: return "\(alias).artistDisplay"
        case .album: return "\(alias).albumTitle"
        case .genre: return "\(alias).genreDisplay"
        case .format: return "\(alias).format"
        default: return "''"
        }
    }

    private static func emptyDateClause(_ field: PlaylistRuleField, historyAlias: String) -> String {
        switch field {
        case .lastQualifiedPlayDate:
            return "\(historyAlias).lastQualifiedAtUTC IS NULL"
        case .qualifiedPlayDate:
            return "COALESCE(\(historyAlias).qualifiedPlayCount, 0) = 0"
        case .firstSeen:
            return "0 = 1"
        default:
            return "0 = 1"
        }
    }

    private static func nonemptyDateClause(_ field: PlaylistRuleField, historyAlias: String) -> String {
        switch field {
        case .lastQualifiedPlayDate:
            return "\(historyAlias).lastQualifiedAtUTC IS NOT NULL"
        case .qualifiedPlayDate:
            return "COALESCE(\(historyAlias).qualifiedPlayCount, 0) > 0"
        case .firstSeen:
            return "0 = 1"
        default:
            return "0 = 1"
        }
    }

    private static func dateClause(
        _ clause: PlaylistDateClause,
        arguments: inout StatementArguments
    ) throws -> String {
        if clause.field == .qualifiedPlayDate {
            return try qualifiedPlayDateClause(clause, arguments: &arguments)
        }
        let expression: String
        switch clause.field {
        case .firstSeen: expression = "\(clause.trackAlias).firstSeenAtUTC"
        case .lastQualifiedPlayDate: expression = "\(clause.historyAlias).lastQualifiedAtUTC"
        default: throw invalidRule("field is not a date")
        }
        switch clause.operation {
        case .onOrAfter:
            let range = try dateRange(for: clause.start, through: clause.start)
            arguments += [range.start]
            return "\(expression) >= ?"
        case .onOrBefore:
            let range = try dateRange(for: clause.start, through: clause.start)
            arguments += [range.endExclusive]
            return "\(expression) < ?"
        case .between:
            let range = try dateRange(for: clause.start, through: clause.end)
            arguments += [range.start, range.endExclusive]
            return "\(expression) >= ? AND \(expression) < ?"
        default:
            throw invalidRule("operator is not supported for dates")
        }
    }

    private static func qualifiedPlayDateClause(
        _ clause: PlaylistDateClause,
        arguments: inout StatementArguments
    ) throws -> String {
        let eventStart = "playlistRuleEvents.qualifiedAtUTC"
        let eventPredicate: String
        switch clause.operation {
        case .onOrAfter:
            let range = try dateRange(for: clause.start, through: clause.start)
            arguments += [range.start]
            eventPredicate = "\(eventStart) >= ?"
        case .onOrBefore:
            let range = try dateRange(for: clause.start, through: clause.start)
            arguments += [range.endExclusive]
            eventPredicate = "\(eventStart) < ?"
        case .between:
            let range = try dateRange(for: clause.start, through: clause.end)
            arguments += [range.start, range.endExclusive]
            eventPredicate = "\(eventStart) >= ? AND \(eventStart) < ?"
        default:
            throw invalidRule("operator is not supported for qualified-play dates")
        }
        return """
            EXISTS (
                SELECT 1
                FROM listeningEvents playlistRuleEvents
                JOIN listeningMediaSnapshots playlistRuleSnapshots
                  ON playlistRuleSnapshots.id = playlistRuleEvents.snapshotId
                WHERE playlistRuleSnapshots.liveTrackId = \(clause.trackAlias).id
                  AND playlistRuleEvents.qualifiedAtUTC IS NOT NULL
                  AND \(eventPredicate)
            )
            """
    }

    private static func dateRange(
        for start: ListeningLocalDay,
        through end: ListeningLocalDay
    ) throws -> ListeningDateRange {
        guard let range = LibraryDatabase.currentTimeZoneDateRange(from: start, through: end) else {
            throw invalidRule("date is outside the supported range")
        }
        return range
    }

    private static func invalidRule(_ reason: String) -> LibraryDatabaseError {
        .invalidPlaylistDefinition(reason)
    }
}

func compileSmartPlaylistRules(_ rulesJSON: String) throws -> PlaylistSQLCompilation {
    do {
        return try PlaylistRuleCompiler.compile(rulesJSON: rulesJSON)
    } catch let error as PlaylistRuleValidationError {
        throw LibraryDatabaseError.invalidSmartPlaylistRules(error)
    }
}

extension LibraryDatabase {
    static let playlistHistoryJoin = """
        LEFT JOIN (
            SELECT s.liveTrackId AS trackID,
                   COUNT(e.qualifiedAtUTC) AS qualifiedPlayCount,
                   MAX(e.qualifiedAtUTC) AS lastQualifiedAtUTC,
                   COALESCE(SUM(COALESCE(eventListening.listenedSeconds, 0)), 0) AS listenedSeconds
            FROM listeningEvents e
            JOIN listeningMediaSnapshots s ON s.id = e.snapshotId
            LEFT JOIN (
                SELECT eventId, SUM(actualListenedSeconds) AS listenedSeconds
                FROM listeningEventDays
                GROUP BY eventId
            ) eventListening ON eventListening.eventId = e.id
            WHERE s.liveTrackId IS NOT NULL
            GROUP BY s.liveTrackId
        ) playlistHistory ON playlistHistory.trackID = tracks.id
        """
}
