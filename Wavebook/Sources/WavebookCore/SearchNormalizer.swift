import Foundation

struct TrackSearchFields {
    let title: String
    let artistDisplay: String
    let albumTitle: String
    let albumArtist: String?
    let genreDisplay: String
    let path: String
}

/// Normalizes catalog search text.
public enum SearchNormalizer {
    /// Normalizes text for case-, diacritic-, and width-insensitive search.
    public static func normalizedText(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var output = ""
        output.reserveCapacity(folded.count)

        for scalar in folded.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                output.append(" ")
            } else if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
            } else if !CharacterSet.punctuationCharacters.contains(scalar) {
                output.append(" ")
            }
        }

        return output
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
    static func trackSearchText(_ fields: TrackSearchFields) -> String {
        normalizedText([
            fields.title,
            fields.artistDisplay,
            fields.albumTitle,
            fields.albumArtist ?? "",
            fields.genreDisplay,
            URL(fileURLWithPath: fields.path).lastPathComponent
        ].joined(separator: " "))
    }

    /// Splits normalized text into bounded search tokens.
    public static func tokens(_ value: String) -> [String] {
        Array(normalizedText(value).split(separator: " ").prefix(16)).map(String.init)
    }

    /// Returns whether normalized query tokens occur in fields.
    public static func matches(query: String, fields: [String]) -> Bool {
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return true }

        let haystack = normalizedText(fields.joined(separator: " "))
        return queryTokens.allSatisfy { haystack.contains($0) }
    }
}
