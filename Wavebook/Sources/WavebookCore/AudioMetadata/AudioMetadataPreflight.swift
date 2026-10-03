import Foundation

enum AudioMetadataContainer {
    case id3
    case flac
    case ogg
    case riff
    case aiff
    case caf
    case iso
    case ape
}

enum AudioMetadataPreflight {
    static func allowsAVFoundationMetadata(for url: URL) throws -> Bool {
        try Task.checkCancellation()
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isReadable == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              let fileSize = UInt64(exactly: fileSize),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }

        var reader = BoundedFileReader(handle: handle, fileSize: fileSize, limit: fileSize)
        var budget = AudioMetadataBudget()
        let signatureLength = Int(min(fileSize, UInt64(16)))
        guard let signature = try reader.read(count: signatureLength, budget: &budget),
              reader.seek(to: 0) else { return false }
        guard let container = container(for: signature) else {
            return try AudioMetadataAPEValidation.validateTail(from: &reader, budget: &budget, requireTag: true)
        }
        return try validateContainer(container, from: &reader, budget: &budget)
    }

    private static func validateContainer(
        _ container: AudioMetadataContainer,
        from reader: inout BoundedFileReader,
        budget: inout AudioMetadataBudget
    ) throws -> Bool {
        switch container {
        case .id3:
            guard try AudioMetadataID3Validation.validate(from: &reader, budget: &budget) else { return false }
            return try AudioMetadataAPEValidation.validateTail(from: &reader, budget: &budget, requireTag: false)
        case .flac:
            return try AudioMetadataFLACValidation.validate(from: &reader, budget: &budget)
        case .ogg:
            return try AudioMetadataOpusValidation.validate(from: &reader, budget: &budget)
        case .riff, .aiff, .caf:
            return try validateChunkedContainer(container, from: &reader, budget: &budget)
        case .iso, .ape:
            return try validateOtherContainer(container, from: &reader, budget: &budget)
        }
    }

    private static func validateChunkedContainer(
        _ container: AudioMetadataContainer,
        from reader: inout BoundedFileReader,
        budget: inout AudioMetadataBudget
    ) throws -> Bool {
        switch container {
        case .riff:
            return try AudioMetadataChunkedValidation.validateRIFF(from: &reader, budget: &budget)
        case .aiff:
            return try AudioMetadataChunkedValidation.validateAIFF(from: &reader, budget: &budget)
        case .caf:
            return try AudioMetadataChunkedValidation.validateCAF(from: &reader, budget: &budget)
        default:
            return false
        }
    }

    private static func validateOtherContainer(
        _ container: AudioMetadataContainer,
        from reader: inout BoundedFileReader,
        budget: inout AudioMetadataBudget
    ) throws -> Bool {
        switch container {
        case .iso:
            return try AudioMetadataISOValidation.validate(from: &reader, budget: &budget)
        case .ape:
            return try AudioMetadataAPEValidation.validateHeader(from: &reader, budget: &budget)
        default:
            return false
        }
    }

    private static func container(for signature: Data) -> AudioMetadataContainer? {
        if AudioMetadataBinarySupport.starts(signature, with: [0x49, 0x44, 0x33]) { return .id3 }
        if AudioMetadataBinarySupport.starts(signature, with: [0x66, 0x4C, 0x61, 0x43]) { return .flac }
        if AudioMetadataBinarySupport.starts(signature, with: [0x4F, 0x67, 0x67, 0x53]) { return .ogg }
        if AudioMetadataBinarySupport.starts(signature, with: [0x52, 0x49, 0x46, 0x46]),
            AudioMetadataBinarySupport.starts(signature, with: [0x57, 0x41, 0x56, 0x45], at: 8) {
            return .riff
        }
        if AudioMetadataBinarySupport.starts(signature, with: [0x46, 0x4F, 0x52, 0x4D]),
            AudioMetadataBinarySupport.starts(signature, with: [0x41, 0x49, 0x46, 0x46], at: 8) ||
             AudioMetadataBinarySupport.starts(signature, with: [0x41, 0x49, 0x46, 0x43], at: 8) {
            return .aiff
        }
        if AudioMetadataBinarySupport.starts(signature, with: [0x63, 0x61, 0x66, 0x66]) { return .caf }
        if signature.count >= 8,
           [
               [0x66, 0x74, 0x79, 0x70],
               [0x6D, 0x6F, 0x6F, 0x76],
               [0x6D, 0x64, 0x61, 0x74],
               [0x66, 0x72, 0x65, 0x65]
           ].contains(Array(signature[4..<8])) {
            return .iso
        }
        if AudioMetadataBinarySupport.starts(signature, with: Array("APETAGEX".utf8)) { return .ape }
        return nil
    }
}
