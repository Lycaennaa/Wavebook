import Foundation

private struct GregorianComponents {
    let year: Int
    let month: Int
    let day: Int
}

/// A validated local calendar day in YYYY-MM-DD form.
public struct ListeningLocalDay: RawRepresentable, Codable, Comparable, Hashable, Sendable, CustomStringConvertible {
    /// Canonical YYYY-MM-DD representation.
    public let rawValue: String

    /// Creates a local day from its canonical representation.
    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Creates a local day from its canonical representation.
    public init?(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    /// Creates a local day from Gregorian components.
    public init?(year: Int, month: Int, day: Int) {
        guard (0...9999).contains(year), Self.isValid(year: year, month: month, day: day) else {
            return nil
        }

        self.rawValue = String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Creates the local day containing a UTC date in a time zone.
    public init?(date: Date, timeZone: TimeZone) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }

        let localSeconds = date.timeIntervalSince1970
            + Double(timeZone.secondsFromGMT(for: date))
        let localDayNumber = floor(localSeconds / 86_400)
        guard localDayNumber.isFinite, (-4_000_000.0...4_000_000.0).contains(localDayNumber) else {
            return nil
        }

        let components = Self.prolepticGregorianComponents(dayNumberSince1970: Int64(localDayNumber))
        self.init(year: components.year, month: components.month, day: components.day)
    }

    /// Gregorian year.
    public var year: Int { Int(rawValue.prefix(4)) ?? 0 }
    /// Gregorian month.
    public var month: Int { Int(rawValue.dropFirst(5).prefix(2)) ?? 0 }
    /// Gregorian day of the month.
    public var day: Int { Int(rawValue.dropFirst(8).prefix(2)) ?? 0 }
    /// Canonical textual description.
    public var description: String { rawValue }

    /// Compares canonical day representations.
    public static func < (lhs: ListeningLocalDay, rhs: ListeningLocalDay) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Decodes a local day from a single string value.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let day = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid listening local day"
            )
        }
        self = day
    }

    /// Encodes the canonical day representation.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func prolepticGregorianComponents(dayNumberSince1970 dayNumber: Int64) -> GregorianComponents {
        let shifted = dayNumber + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthOfYear = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthOfYear + 2) / 5 + 1
        let month = monthOfYear + (monthOfYear < 10 ? 3 : -9)
        let fullYear = year + (month <= 2 ? 1 : 0)
        return GregorianComponents(year: Int(fullYear), month: Int(month), day: Int(day))
    }

    private static func isValid(_ rawValue: String) -> Bool {
        let bytes = Array(rawValue.utf8)
        guard
            bytes.count == 10,
            bytes[4] == 45,
            bytes[7] == 45,
            bytes[0..<4].allSatisfy({ (48...57).contains($0) }),
            bytes[5..<7].allSatisfy({ (48...57).contains($0) }),
            bytes[8..<10].allSatisfy({ (48...57).contains($0) })
        else {
            return false
        }

        guard
            let yearString = String(bytes: bytes[0..<4], encoding: .utf8),
            let monthString = String(bytes: bytes[5..<7], encoding: .utf8),
            let dayString = String(bytes: bytes[8..<10], encoding: .utf8),
            let year = Int(yearString),
            let month = Int(monthString),
            let day = Int(dayString)
        else {
            return false
        }

        return isValid(year: year, month: month, day: day)
    }

    private static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month) else { return false }

        let daysInMonth: [Int] = [
            31,
            isLeapYear(year) ? 29 : 28,
            31,
            30,
            31,
            30,
            31,
            31,
            30,
            31,
            30,
            31
        ]
        return (1...daysInMonth[month - 1]).contains(day)
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }
}
