import Foundation

enum AudioISOArtworkReader {
    static func artworkData(from reader: inout BoundedFileReader) -> Data? {
        while reader.offset + 8 <= reader.limit {
            guard !Task.isCancelled,
                  let atom = readAtom(from: &reader, end: reader.limit),
                  let type = String(bytes: atom.type, encoding: .utf8) else { return nil }
            if type == "moov",
               let artwork = readContainer(atom, from: &reader, depth: 0),
               AudioArtworkImageSupport.isValidArtworkData(artwork) {
                return artwork
            }
            guard reader.seek(to: atom.end) else { return nil }
        }
        return nil
    }

    private static func readContainer(_ atom: ISOAtom, from reader: inout BoundedFileReader, depth: Int) -> Data? {
        guard depth <= 8,
              let type = String(bytes: atom.type, encoding: .utf8) else { return nil }
        if type == "data" {
            return readData(atom, from: &reader)
        }
        if type == "meta" {
            guard atom.end - atom.dataStart >= 4,
                  reader.seek(to: atom.dataStart + 4) else { return nil }
        } else {
            guard reader.seek(to: atom.dataStart) else { return nil }
        }
        return readChildren(of: atom, from: &reader, depth: depth)
    }

    private static func readChildren(of atom: ISOAtom, from reader: inout BoundedFileReader, depth: Int) -> Data? {
        while reader.offset + 8 <= atom.end {
            guard !Task.isCancelled,
                  let child = readAtom(from: &reader, end: atom.end),
                  let childType = String(bytes: child.type, encoding: .utf8) else { return nil }
            guard isContainerType(childType) else {
                guard reader.seek(to: child.end) else { return nil }
                continue
            }
            if let artwork = readContainer(child, from: &reader, depth: depth + 1),
               AudioArtworkImageSupport.isValidArtworkData(artwork) {
                return artwork
            }
            guard reader.seek(to: child.end) else { return nil }
        }
        return nil
    }

    private static func readData(_ atom: ISOAtom, from reader: inout BoundedFileReader) -> Data? {
        guard atom.end - atom.dataStart >= 8,
              reader.seek(to: atom.dataStart),
              reader.skip(8) else { return nil }
        let dataLength = atom.end - reader.offset
        guard dataLength > 0,
              dataLength <= UInt64(AudioArtworkLimits.maximumArtworkBytes),
              dataLength <= UInt64(Int.max),
              let artwork = AudioArtworkFormatSupport.readData(
                  from: &reader,
                  count: Int(dataLength),
                  maximumBytes: UInt64(AudioArtworkLimits.maximumArtworkBytes),
                  maximumReadChunkBytes: AudioArtworkLimits.maximumReadChunkBytes
              ) else { return nil }
        return AudioArtworkImageSupport.isValidArtworkData(artwork) ? artwork : nil
    }

    private static func readAtom(from reader: inout BoundedFileReader, end: UInt64) -> ISOAtom? {
        let start = reader.offset
        guard start + 8 <= end,
              let header = reader.read(count: 8) else { return nil }
        var headerSize: UInt64 = 8
        var atomSize = UInt64(AudioArtworkFormatSupport.bigEndianUInt32(header, at: 0) ?? 0)
        if atomSize == 1 {
            guard let extendedSize = AudioArtworkFormatSupport.readBigEndianUInt64(from: &reader) else { return nil }
            atomSize = extendedSize
            headerSize = 16
        } else if atomSize == 0 {
            atomSize = end - start
        }
        guard atomSize >= headerSize, atomSize <= end - start else { return nil }
        return ISOAtom(type: Array(header[4..<8]), dataStart: start + headerSize, end: start + atomSize)
    }

    private static func isContainerType(_ type: String) -> Bool {
        type == "moov" || type == "udta" || type == "meta" || type == "ilst" || type == "covr" || type == "data"
    }

    private struct ISOAtom {
        let type: [UInt8]
        let dataStart: UInt64
        let end: UInt64
    }
}
