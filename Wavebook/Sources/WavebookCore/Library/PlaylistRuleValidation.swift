import Foundation

/// Bounds enforced before a smart definition reaches SQL compilation.
public enum PlaylistRuleLimits {
    /// Maximum number of flat predicates.
    public static let maximumRuleCount = 32
    /// Maximum UTF-8 bytes in one value.
    public static let maximumValueLength = 512
    /// Maximum UTF-8 bytes in encoded rules JSON.
    public static let maximumJSONLength = 16_384
}

/// Validation errors for smart-playlist rules.
public enum PlaylistRuleValidationError: Error, Equatable, Sendable, LocalizedError {
    /// The JSON root or one of its values is malformed.
    case invalidJSON
    /// The flat rule count exceeds the supported bound.
    case tooManyRules(limit: Int)
    /// One rule violates the supported field/operator grammar.
    case invalidRule(index: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "The smart-playlist rules are not valid JSON."
        case let .tooManyRules(limit): return "A smart playlist supports at most \(limit) rules."
        case let .invalidRule(index, reason): return "Invalid smart-playlist rule \(index + 1): \(reason)."
        }
    }
}

enum ValidatedPlaylistRuleValue: Equatable, Hashable, Sendable {
    case none
    case text(String)
    case number(Double)
    case dateRange(start: ListeningLocalDay, end: ListeningLocalDay)
}

struct ValidatedPlaylistRule: Equatable, Hashable, Sendable {
    let field: PlaylistRuleField
    let operation: PlaylistRuleOperator
    let value: ValidatedPlaylistRuleValue
}

/// Parses and validates the bounded smart-playlist grammar.
public enum PlaylistRuleValidator {
    /// Parses a JSON array or `{ "rules": [...] }` wrapper.
    public static func parse(_ rulesJSON: String) throws -> [PlaylistRule] {
        let rules = try decodeRules(from: rulesJSON)
        _ = try validatedRules(rules)
        return rules
    }

    /// Validates already-decoded rules.
    public static func validate(_ rules: [PlaylistRule]) throws {
        _ = try validatedRules(rules)
    }

    /// Encodes and validates a rule list in canonical array form.
    public static func encode(_ rules: [PlaylistRule]) throws -> String {
        _ = try validatedRules(rules)
        let data: Data
        do {
            data = try JSONEncoder().encode(rules)
        } catch {
            throw PlaylistRuleValidationError.invalidJSON
        }
        guard data.count <= PlaylistRuleLimits.maximumJSONLength,
              let result = String(data: data, encoding: .utf8) else {
            throw PlaylistRuleValidationError.invalidJSON
        }
        return result
    }

    static func validatedRules(from rulesJSON: String) throws -> [ValidatedPlaylistRule] {
        try validatedRules(decodeRules(from: rulesJSON))
    }

    static func validatedRules(_ rules: [PlaylistRule]) throws -> [ValidatedPlaylistRule] {
        guard rules.count <= PlaylistRuleLimits.maximumRuleCount else {
            throw PlaylistRuleValidationError.tooManyRules(limit: PlaylistRuleLimits.maximumRuleCount)
        }
        return try rules.enumerated().map { index, rule in
            try validatedRule(rule, at: index)
        }
    }

    private static func decodeRules(from rulesJSON: String) throws -> [PlaylistRule] {
        let data = Data(rulesJSON.utf8)
        guard !data.isEmpty, data.count <= PlaylistRuleLimits.maximumJSONLength else {
            throw PlaylistRuleValidationError.invalidJSON
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw PlaylistRuleValidationError.invalidJSON
        }
        let rootRules: [Any]?
        if root is [Any] {
            rootRules = root as? [Any]
        } else if let object = root as? [String: Any] {
            let allowedRootKeys = Set(["rules", "match"])
            let matchIsAll = object["match"] == nil
                || (object["match"] as? String)?.lowercased() == "all"
            guard object.keys.allSatisfy(allowedRootKeys.contains), matchIsAll else {
                throw PlaylistRuleValidationError.invalidJSON
            }
            rootRules = object["rules"] as? [Any]
        } else {
            rootRules = nil
        }
        let allowedRuleKeys = Set(["field", "operator", "operation", "op", "value"])
        guard let rootRules,
              rootRules.allSatisfy({ candidate in
                  guard let object = candidate as? [String: Any],
                        object.keys.allSatisfy(allowedRuleKeys.contains),
                        object["field"] != nil else { return false }
                  let operatorKeyCount = ["operator", "operation", "op"]
                      .filter { object[$0] != nil }
                      .count
                  return operatorKeyCount == 1
              }) else {
            throw PlaylistRuleValidationError.invalidJSON
        }

        do {
            if root is [Any] {
                return try JSONDecoder().decode([PlaylistRule].self, from: data)
            }
            return try JSONDecoder().decode(SmartPlaylistRuleSet.self, from: data).rules
        } catch {
            throw PlaylistRuleValidationError.invalidJSON
        }
    }

    private static func validatedRule(
        _ rule: PlaylistRule,
        at index: Int
    ) throws -> ValidatedPlaylistRule {
        if let value = rule.value, value.utf8.count > PlaylistRuleLimits.maximumValueLength {
            throw invalidRule(index, "value is too long")
        }
        switch rule.field {
        case .title, .artist, .album, .genre, .format:
            return try validatedTextRule(rule, index: index)
        case .duration, .qualifiedPlayCount:
            return try validatedNumericRule(rule, index: index)
        case .firstSeen:
            return try validatedDateRule(rule, index: index, allowsEmpty: false)
        case .lastQualifiedPlayDate, .qualifiedPlayDate:
            return try validatedDateRule(rule, index: index, allowsEmpty: true)
        }
    }

    private static func validatedTextRule(
        _ rule: PlaylistRule,
        index: Int
    ) throws -> ValidatedPlaylistRule {
        switch rule.operation {
        case .contains:
            guard let value = rule.value, !SearchNormalizer.normalizedText(value).isEmpty else {
                throw invalidRule(index, "contains requires a nonempty value")
            }
            return ValidatedPlaylistRule(field: rule.field, operation: rule.operation, value: .text(value))
        case .isEmpty, .isNotEmpty:
            try requireNoValue(rule, index: index)
            return ValidatedPlaylistRule(field: rule.field, operation: rule.operation, value: .none)
        default:
            throw invalidRule(index, "operator is not supported for text")
        }
    }

    private static func validatedNumericRule(
        _ rule: PlaylistRule,
        index: Int
    ) throws -> ValidatedPlaylistRule {
        switch rule.operation {
        case .greaterThan, .lessThan:
            guard let value = rule.value, let number = Double(value), number.isFinite else {
                throw invalidRule(index, "value must be a finite number")
            }
            return ValidatedPlaylistRule(field: rule.field, operation: rule.operation, value: .number(number))
        default:
            throw invalidRule(index, "numeric fields support only greater-than and less-than")
        }
    }

    private static func validatedDateRule(
        _ rule: PlaylistRule,
        index: Int,
        allowsEmpty: Bool
    ) throws -> ValidatedPlaylistRule {
        switch rule.operation {
        case .onOrAfter, .onOrBefore:
            let day = try requireDate(rule.value, index: index)
            return ValidatedPlaylistRule(
                field: rule.field,
                operation: rule.operation,
                value: .dateRange(start: day, end: day)
            )
        case .between:
            let (start, end) = try requireDateRange(rule.value, index: index)
            return ValidatedPlaylistRule(
                field: rule.field,
                operation: rule.operation,
                value: .dateRange(start: start, end: end)
            )
        case .isEmpty, .isNotEmpty:
            guard allowsEmpty else {
                throw invalidRule(index, "first-seen date does not support empty checks")
            }
            try requireNoValue(rule, index: index)
            return ValidatedPlaylistRule(field: rule.field, operation: rule.operation, value: .none)
        default:
            throw invalidRule(index, "operator is not supported for dates")
        }
    }

    private static func requireNoValue(_ rule: PlaylistRule, index: Int) throws {
        guard rule.value == nil else { throw invalidRule(index, "operator does not accept a value") }
    }

    private static func requireDate(_ value: String?, index: Int) throws -> ListeningLocalDay {
        guard let value,
              let day = ListeningLocalDay(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw invalidRule(index, "value must be a YYYY-MM-DD date")
        }
        return day
    }

    private static func requireDateRange(
        _ value: String?,
        index: Int
    ) throws -> (start: ListeningLocalDay, end: ListeningLocalDay) {
        guard let value else { throw invalidRule(index, "date range requires two dates") }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = ListeningLocalDay(String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)),
              let end = ListeningLocalDay(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)),
              start <= end else {
            throw invalidRule(index, "date range must contain two ordered YYYY-MM-DD dates")
        }
        return (start, end)
    }

    private static func invalidRule(_ index: Int, _ reason: String) -> PlaylistRuleValidationError {
        .invalidRule(index: index, reason: reason)
    }
}
