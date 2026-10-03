import Foundation

enum AudioMetadataOpusValidation {
    private enum PageResult {
        case invalid
        case continueReading
        case finished(Bool)
    }

    private struct PacketState {
        var number = 0
        var data = Data()
    }

    static func validate(from reader: inout BoundedFileReader, budget: inout AudioMetadataBudget) throws -> Bool {
        guard reader.limit >= 27 else { return false }
        var state = PacketState()

        while reader.offset + 27 <= reader.limit {
            try Task.checkCancellation()
            switch try readPage(from: &reader, budget: &budget, state: &state) {
            case .invalid:
                return false
            case .continueReading:
                continue
            case .finished(let isValid):
                return isValid
            }
        }
        return false
    }

    private static func readPage(
        from reader: inout BoundedFileReader,
        budget: inout AudioMetadataBudget,
        state: inout PacketState
    ) throws -> PageResult {
        guard let pageHeader = try reader.read(count: 27, budget: &budget),
              AudioMetadataBinarySupport.starts(pageHeader, with: [0x4F, 0x67, 0x67, 0x53]),
              pageHeader[4] == 0 else { return .invalid }
        let segmentCount = Int(pageHeader[26])
        guard let lacing = try reader.read(count: segmentCount, budget: &budget) else { return .invalid }
        let payloadLength = lacing.reduce(0) { $0 + Int($1) }
        guard let payload = try reader.read(count: payloadLength, budget: &budget) else { return .invalid }
        return try processSegments(lacing: lacing, payload: payload, budget: &budget, state: &state)
    }

    private static func processSegments(
        lacing: Data,
        payload: Data,
        budget: inout AudioMetadataBudget,
        state: inout PacketState
    ) throws -> PageResult {
        var payloadOffset = 0
        for segmentLengthByte in lacing {
            switch try processSegment(
                segmentLengthByte,
                payload: payload,
                payloadOffset: &payloadOffset,
                budget: &budget,
                state: &state
            ) {
            case .invalid:
                return .invalid
            case .continueReading:
                continue
            case .finished(let isValid):
                return .finished(isValid)
            }
        }
        return .continueReading
    }

    private static func processSegment(
        _ segmentLengthByte: UInt8,
        payload: Data,
        payloadOffset: inout Int,
        budget: inout AudioMetadataBudget,
        state: inout PacketState
    ) throws -> PageResult {
        let segmentLength = Int(segmentLengthByte)
        let segmentEnd = payloadOffset + segmentLength
        guard segmentEnd <= payload.count else { return .invalid }
        try appendSegment(
            payload[payloadOffset..<segmentEnd],
            length: segmentLength,
            state: &state
        )
        payloadOffset = segmentEnd
        guard segmentLength < 255 else { return .continueReading }
        return try completePacket(state: &state, budget: &budget)
    }

    private static func appendSegment(_ segment: Data.SubSequence, length: Int, state: inout PacketState) throws {
        guard state.number < 2 else { return }
        guard state.data.count <= AudioMetadataLimits.maximumMetadataBytes - length else {
            throw AudioMetadataError.metadataTooLarge
        }
        state.data.append(segment)
    }

    private static func completePacket(
        state: inout PacketState,
        budget: inout AudioMetadataBudget
    ) throws -> PageResult {
        if state.number == 0 {
            guard AudioMetadataBinarySupport.starts(state.data, with: Array("OpusHead".utf8)) else { return .invalid }
            state.data.removeAll(keepingCapacity: false)
            state.number += 1
            return .continueReading
        }
        if state.number == 1 {
            guard AudioMetadataBinarySupport.starts(state.data, with: Array("OpusTags".utf8)) else { return .invalid }
            return .finished(try validateTags(state.data, budget: &budget))
        }
        state.data.removeAll(keepingCapacity: false)
        state.number += 1
        return .continueReading
    }

    private static func validateTags(_ packet: Data, budget: inout AudioMetadataBudget) throws -> Bool {
        guard packet.count >= 16,
              AudioMetadataBinarySupport.starts(packet, with: Array("OpusTags".utf8)),
              let vendorLength = AudioMetadataBinarySupport.littleEndianUInt32(packet, at: 8),
              vendorLength <= UInt32(packet.count - 12) else { return false }
        var cursor = 12 + Int(vendorLength)
        guard let commentCount = AudioMetadataBinarySupport.littleEndianUInt32(packet, at: cursor),
              let commentCount = Int(exactly: commentCount),
              commentCount <= AudioMetadataLimits.maximumMetadataItemCount else {
            throw AudioMetadataError.tooManyMetadataItems
        }
        cursor += 4
        try budget.add(bytes: UInt64(packet.count), itemCount: commentCount)
        for _ in 0..<commentCount {
            guard cursor <= packet.count - 4,
                  let commentLength = AudioMetadataBinarySupport.littleEndianUInt32(packet, at: cursor),
                  let commentLength = Int(exactly: commentLength),
                  commentLength <= packet.count - cursor - 4 else { return false }
            cursor += 4 + commentLength
        }
        return cursor <= packet.count
    }
}
