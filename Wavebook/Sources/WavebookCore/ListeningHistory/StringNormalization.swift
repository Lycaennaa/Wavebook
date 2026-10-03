import Foundation

extension String {
    var listeningTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var listeningTrimmedOrNil: String? {
        let value = listeningTrimmed
        return value.isEmpty ? nil : value
    }
}
