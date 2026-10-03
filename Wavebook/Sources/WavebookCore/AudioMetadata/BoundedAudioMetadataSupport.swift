import Foundation

enum AudioMetadataLimits {
    static let maximumMetadataItemCount = 512
    static let maximumMetadataValueLength = 4_096
    static let maximumMergedValueLength = 16_384
    static let maximumMergedValueCount = 64
    static let maximumMetadataIdentifierLength = 256
    static let maximumMetadataBytes = 10485760
    static let maximumExtraAttributeCount = 16
    static let maximumMetadataProbeBytes: UInt64 = 8 * 1_024 * 1_024
    static let maximumMetadataContainerDepth = 8
}

enum AudioMetadataValueBounds {
    static func trimmed(
        _ value: String,
        maximumLength: Int = AudioMetadataLimits.maximumMetadataValueLength
    ) -> String? {
        guard maximumLength > 0 else { return nil }
        let bounded = String(value.prefix(maximumLength))
        let trimmed = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func key(_ value: String) -> String {
        String(value.prefix(AudioMetadataLimits.maximumMetadataIdentifierLength)).lowercased()
    }
}

struct BoundedMetadataField {
    private(set) var value: String?
    private(set) var count = 0

    mutating func append(_ rawValue: String) {
        guard count < AudioMetadataLimits.maximumMergedValueCount,
              let value = AudioMetadataValueBounds.trimmed(rawValue),
              !value.isEmpty else { return }

        guard let existing = self.value else {
            self.value = value
            count = 1
            return
        }
        guard existing != value else { return }

        let separator = "; "
        let remainingLength = AudioMetadataLimits.maximumMergedValueLength - existing.count - separator.count
        guard remainingLength > 0 else { return }
        let boundedValue = String(value.prefix(remainingLength))
        guard !boundedValue.isEmpty else { return }
        self.value = existing + separator + boundedValue
        count += 1
    }
}

struct AudioMetadataBudget {
    private(set) var bytes: UInt64 = 0
    private(set) var itemCount = 0
    private(set) var probeBytes: UInt64 = 0

    mutating func add(bytes: UInt64 = 0, itemCount: Int = 0) throws {
        let maximumBytes = UInt64(AudioMetadataLimits.maximumMetadataBytes)
        guard self.bytes <= maximumBytes,
              bytes <= maximumBytes - self.bytes else {
            throw AudioMetadataError.metadataTooLarge
        }
        guard itemCount >= 0,
              self.itemCount <= AudioMetadataLimits.maximumMetadataItemCount,
              itemCount <= AudioMetadataLimits.maximumMetadataItemCount - self.itemCount else {
            throw AudioMetadataError.tooManyMetadataItems
        }
        self.bytes += bytes
        self.itemCount += itemCount
    }

    mutating func addProbe(bytes: UInt64) throws {
        let maximumBytes = AudioMetadataLimits.maximumMetadataProbeBytes
        guard probeBytes <= maximumBytes,
              bytes <= maximumBytes - probeBytes else {
            throw AudioMetadataError.metadataTooLarge
        }
        probeBytes += bytes
    }
}
