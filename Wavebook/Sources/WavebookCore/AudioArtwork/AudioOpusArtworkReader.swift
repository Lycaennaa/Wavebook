import Foundation

enum AudioOpusArtworkReader {
    private enum PageResult {
        case invalid
        case continueReading
        case finished(Data?)
    }

    private struct PacketState {
        var number = 0
        var data = Data()
        var tooLarge = false
    }

    static func artworkData(from reader: inout BoundedFileReader) -> Data? {
        guard let signature = reader.read(count: 4),
              AudioArtworkFormatSupport.dataStarts(signature, with: [0x4F, 0x67, 0x67, 0x53]),
              reader.seek(to: 0) else { return nil }
        var state = PacketState()

        while reader.offset + 27 <= reader.limit {
            guard !Task.isCancelled else { return nil }
            switch readPage(from: &reader, state: &state) {
            case .invalid:
                return nil
            case .continueReading:
                continue
            case .finished(let artwork):
                return artwork
            }
        }
        return nil
    }

    private static func readPage(from reader: inout BoundedFileReader, state: inout PacketState) -> PageResult {
        guard let pageHeader = reader.read(count: 27),
              AudioArtworkFormatSupport.dataStarts(pageHeader, with: [0x4F, 0x67, 0x67, 0x53]),
              pageHeader[4] == 0 else { return .invalid }
        let segmentCount = Int(pageHeader[26])
        guard let lacing = reader.read(count: segmentCount) else { return .invalid }
        let payloadLength = lacing.reduce(0) { $0 + Int($1) }
        guard let payload = reader.read(count: payloadLength) else { return .invalid }
        return processSegments(lacing: lacing, payload: payload, state: &state)
    }

    private static func processSegments(lacing: Data, payload: Data, state: inout PacketState) -> PageResult {
        var payloadOffset = 0
        for segmentLengthByte in lacing {
            switch processSegment(
                segmentLengthByte,
                payload: payload,
                payloadOffset: &payloadOffset,
                state: &state
            ) {
            case .invalid:
                return .invalid
            case .continueReading:
                continue
            case .finished(let artwork):
                return .finished(artwork)
            }
        }
        return .continueReading
    }

    private static func processSegment(
        _ segmentLengthByte: UInt8,
        payload: Data,
        payloadOffset: inout Int,
        state: inout PacketState
    ) -> PageResult {
        let segmentLength = Int(segmentLengthByte)
        let segmentEnd = payloadOffset + segmentLength
        guard segmentEnd <= payload.count else { return .invalid }
        appendSegment(
            payload[payloadOffset..<segmentEnd],
            length: segmentLength,
            state: &state
        )
        payloadOffset = segmentEnd
        guard segmentLength < 255 else { return .continueReading }
        return completePacket(state: &state)
    }

    private static func appendSegment(_ segment: Data.SubSequence, length: Int, state: inout PacketState) {
        guard state.number < 2, !state.tooLarge else { return }
        if state.data.count > AudioArtworkLimits.maximumOpusPacketBytes - length {
            state.tooLarge = true
        } else {
            state.data.append(segment)
        }
    }

    private static func completePacket(state: inout PacketState) -> PageResult {
        if state.number == 0 {
            guard !state.tooLarge,
                  AudioArtworkFormatSupport.dataStarts(state.data, with: Array("OpusHead".utf8)) else {
                return .invalid
            }
            state.data.removeAll(keepingCapacity: true)
            state.tooLarge = false
            state.number += 1
            return .continueReading
        }
        if state.number == 1 {
            guard !state.tooLarge else { return .invalid }
            return .finished(artworkData(inTagsPacket: state.data))
        }
        state.data.removeAll(keepingCapacity: true)
        state.tooLarge = false
        state.number += 1
        return .continueReading
    }

    private static func artworkData(inTagsPacket packet: Data) -> Data? {
        guard AudioArtworkFormatSupport.dataStarts(packet, with: Array("OpusTags".utf8)),
              packet.count >= 16,
              let vendorLength = AudioArtworkFormatSupport.littleEndianUInt32(packet, at: 8) else { return nil }
        var cursor = 12
        guard vendorLength <= UInt32(packet.count - cursor) else { return nil }
        cursor += Int(vendorLength)
        guard cursor + 4 <= packet.count,
              let commentCount = AudioArtworkFormatSupport.littleEndianUInt32(packet, at: cursor) else { return nil }
        cursor += 4

        for _ in 0..<commentCount {
            guard let comment = nextComment(in: packet, cursor: &cursor) else { return nil }
            if let artwork = artworkData(inComment: comment) {
                return artwork
            }
        }
        return nil
    }

    private static func nextComment(in packet: Data, cursor: inout Int) -> Data? {
        guard cursor + 4 <= packet.count,
              let commentLength = AudioArtworkFormatSupport.littleEndianUInt32(packet, at: cursor) else {
            return nil
        }
        cursor += 4
        guard commentLength <= UInt32(packet.count - cursor) else { return nil }
        let commentEnd = cursor + Int(commentLength)
        let comment = Data(packet[cursor..<commentEnd])
        cursor = commentEnd
        return comment
    }

    private static func artworkData(inComment comment: Data) -> Data? {
        guard let separator = comment.firstIndex(of: 0x3D) else { return nil }
        let key = comment[..<separator].map { byte in
            byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
        }
        let encodedValue = Data(comment[(separator + 1)...])
        guard encodedValue.count <= AudioArtworkLimits.maximumOpusBase64Bytes else { return nil }

        if key.elementsEqual(Array("coverart".utf8)) {
            guard let artwork = Data(base64Encoded: encodedValue),
                  artwork.count <= AudioArtworkLimits.maximumArtworkBytes,
                  AudioArtworkImageSupport.isValidArtworkData(artwork) else { return nil }
            return artwork
        }
        if key.elementsEqual(Array("metadata_block_picture".utf8)),
           let picture = Data(base64Encoded: encodedValue),
           let artwork = AudioFLACArtworkReader.artworkData(inPicture: picture) {
            return artwork
        }
        return nil
    }
}
