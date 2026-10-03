import Foundation

/// A read-only system playlist defined by the application.
public enum SystemPlaylistKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// All live tracks ordered by their best-known first-seen time.
    case recentlyAdded
    /// Live tracks with at least one qualified play.
    case mostPlayed
    /// Live tracks marked as favorites.
    case favorites

    /// Stable identity.
    public var id: Self { self }

    /// User-facing system-playlist name.
    public var displayName: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .mostPlayed: return "Most Played"
        case .favorites: return "Favorites"
        }
    }

    /// Stable numeric identity used for listening-history source attribution.
    public var playbackPersistentID: Int64 {
        switch self {
        case .recentlyAdded: return -1
        case .mostPlayed: return -2
        case .favorites: return -3
        }
    }
}

/// Field exposed by the smart-playlist rule grammar.
public enum PlaylistRuleField: String, CaseIterable, Codable, Hashable, Sendable {
    /// Track title.
    case title
    /// Displayed artist.
    case artist
    /// Album title.
    case album
    /// Displayed genre.
    case genre
    /// Audio format.
    case format
    /// Track duration in seconds.
    case duration
    /// Best-known first-seen date.
    case firstSeen
    /// Number of qualified plays.
    case qualifiedPlayCount
    /// Most recent qualified-play date.
    case lastQualifiedPlayDate
    /// Whether any qualified play occurred in the selected date window.
    case qualifiedPlayDate

    static func fromJSON(_ value: String) -> Self? {
        if let field = Self(rawValue: value) { return field }
        let normalizedValue = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        return [
            "title": Self.title,
            "artist": Self.artist,
            "artistdisplay": Self.artist,
            "album": Self.album,
            "albumtitle": Self.album,
            "genre": Self.genre,
            "genredisplay": Self.genre,
            "format": Self.format,
            "duration": Self.duration,
            "firstseen": Self.firstSeen,
            "firstseenatutc": Self.firstSeen,
            "qualifiedplaycount": Self.qualifiedPlayCount,
            "lastqualifiedplaydate": Self.lastQualifiedPlayDate,
            "lastqualifiedatutc": Self.lastQualifiedPlayDate,
            "qualifiedplaydate": Self.qualifiedPlayDate,
            "qualifieddate": Self.qualifiedPlayDate,
            "qualifiedplayatdate": Self.qualifiedPlayDate
        ][normalizedValue]
    }
}

/// Operator supported by a smart-playlist rule.
public enum PlaylistRuleOperator: String, CaseIterable, Codable, Hashable, Sendable {
    /// Case-insensitive literal substring matching.
    case contains
    /// Strict numeric or date lower bound.
    case greaterThan
    /// Strict numeric or date upper bound.
    case lessThan
    /// Inclusive date lower bound.
    case onOrAfter
    /// Inclusive date upper bound.
    case onOrBefore
    /// Inclusive date range.
    case between
    /// Empty metadata, no qualified plays, or no qualified date.
    case isEmpty
    /// Non-empty metadata, at least one qualified play, or a qualified date.
    case isNotEmpty

    static func fromJSON(_ value: String) -> Self? {
        if let operation = Self(rawValue: value) { return operation }
        switch value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased() {
        case "contains": return .contains
        case "greaterthan", "greater", "gt": return .greaterThan
        case "lessthan", "less", "lt": return .lessThan
        case "onorafter", "after", "dateonorafter": return .onOrAfter
        case "onorbefore", "before", "dateonorbefore": return .onOrBefore
        case "between": return .between
        case "isempty", "empty": return .isEmpty
        case "isnotempty", "notempty", "nonempty": return .isNotEmpty
        default: return nil
        }
    }
}

/// One predicate in a flat, AND-combined smart-playlist definition.
public struct PlaylistRule: Codable, Equatable, Hashable, Sendable {
    /// Metadata or history field selected by the predicate.
    public let field: PlaylistRuleField
    /// Predicate operation.
    public let operation: PlaylistRuleOperator
    /// String representation of the bounded predicate value, when required.
    public let value: String?

    /// Creates a rule with a string value.
    public init(
        field: PlaylistRuleField,
        operation: PlaylistRuleOperator,
        value: String? = nil
    ) {
        self.field = field
        self.operation = operation
        self.value = value
    }

    /// Creates a rule using the ``operator`` label.
    public init(
        field: PlaylistRuleField,
        `operator`: PlaylistRuleOperator,
        value: String? = nil
    ) {
        self.init(field: field, operation: `operator`, value: value)
    }

    /// Creates a rule with a finite numeric value.
    public init(field: PlaylistRuleField, operation: PlaylistRuleOperator, value: Double) {
        self.init(field: field, operation: operation, value: String(value))
    }

    /// Creates a rule with an integer value.
    public init(field: PlaylistRuleField, operation: PlaylistRuleOperator, value: Int) {
        self.init(field: field, operation: operation, value: String(value))
    }

    /// Creates a date rule using the current timezone's local calendar day.
    public init(field: PlaylistRuleField, operation: PlaylistRuleOperator, value: Date) {
        self.init(
            field: field,
            operation: operation,
            value: ListeningLocalDay(date: value, timeZone: .current)?.rawValue
        )
    }

    /// Creates a date rule from a validated local calendar day.
    public init(field: PlaylistRuleField, operation: PlaylistRuleOperator, value: ListeningLocalDay) {
        self.init(field: field, operation: operation, value: value.rawValue)
    }

    /// Operator spelling used by JSON and some clients.
    public var `operator`: PlaylistRuleOperator { operation }

    private enum CodingKeys: String, CodingKey {
        case field
        case operation
        case `operator`
        case operatorAlias = "op"
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let allowedKeys: Set<CodingKeys> = [.field, .operation, .operator, .operatorAlias, .value]
        guard Set(container.allKeys).isSubset(of: allowedKeys) else {
            throw DecodingError.dataCorruptedError(
                forKey: .field,
                in: container,
                debugDescription: "unknown playlist rule key"
            )
        }
        guard let fieldString = try container.decodeIfPresent(String.self, forKey: .field),
              let field = PlaylistRuleField.fromJSON(fieldString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .field,
                in: container,
                debugDescription: "invalid playlist rule field"
            )
        }
        let operatorKeys = [CodingKeys.operator, .operation, .operatorAlias].filter(container.contains)
        guard operatorKeys.count == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .operator,
                in: container,
                debugDescription: "exactly one playlist rule operator key is required"
            )
        }
        let operationString = try container.decode(String.self, forKey: operatorKeys[0])
        guard let operation = PlaylistRuleOperator.fromJSON(operationString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .operator,
                in: container,
                debugDescription: "invalid playlist rule operator"
            )
        }
        self.field = field
        self.operation = operation
        self.value = try Self.decodeValue(from: container)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(field.rawValue, forKey: .field)
        try container.encode(operation.rawValue, forKey: .operator)
        try container.encodeIfPresent(value, forKey: .value)
    }

    private static func decodeValue(from container: KeyedDecodingContainer<CodingKeys>) throws -> String? {
        guard container.contains(.value), try !container.decodeNil(forKey: .value) else { return nil }
        if let value = try? container.decode(String.self, forKey: .value) { return value }
        if let values = try? container.decode([String].self, forKey: .value) {
            return values.joined(separator: ",")
        }
        if let values = try? container.decode([String: String].self, forKey: .value) {
            guard Set(values.keys) == Set(["start", "end"]),
                  let start = values["start"], let end = values["end"] else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "date range value has unknown or missing keys"
                )
            }
            return "\(start),\(end)"
        }
        if let value = try? container.decode(Double.self, forKey: .value) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "nonfinite playlist rule value"
                )
            }
            return String(value)
        }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(codingPath: container.codingPath, debugDescription: "invalid playlist rule value")
        )
    }
}

/// A JSON wrapper for a flat smart-playlist rule list.
public struct SmartPlaylistRuleSet: Codable, Equatable, Hashable, Sendable {
    /// Rules combined with AND.
    public let rules: [PlaylistRule]

    /// Creates a rule set.
    public init(rules: [PlaylistRule]) {
        self.rules = rules
    }
}
