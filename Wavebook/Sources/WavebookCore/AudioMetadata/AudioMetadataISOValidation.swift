import Foundation

struct AudioMetadataISOAtom {
    let type: [UInt8]
    let start: UInt64
    let dataStart: UInt64
    let end: UInt64
}

enum AudioMetadataISOValidation {
    static func validate(from reader: inout BoundedFileReader, budget: inout AudioMetadataBudget) throws -> Bool {
        var sawAtom = false
        while reader.offset + 8 <= reader.limit {
            try Task.checkCancellation()
            guard let atom = try readAtom(from: &reader, end: reader.limit, budget: &budget) else { return false }
            sawAtom = true
            if isContainer(atom.type) {
                guard try inspect(atom, from: &reader, depth: 0, budget: &budget) else { return false }
            }
            guard reader.seek(to: atom.end) else { return false }
        }
        return sawAtom && reader.offset == reader.limit
    }

    private static func inspect(
        _ atom: AudioMetadataISOAtom,
        from reader: inout BoundedFileReader,
        depth: Int,
        budget: inout AudioMetadataBudget
    ) throws -> Bool {
        guard depth <= AudioMetadataLimits.maximumMetadataContainerDepth else { return false }
        if isMetadataContainer(atom.type) {
            try budget.add(bytes: atom.end - atom.start)
            return try inspectMetadataChildren(atom, from: &reader, depth: depth + 1, budget: &budget)
        }
        guard isTraversalContainer(atom.type) else { return true }

        guard reader.seek(to: atom.dataStart) else { return false }
        while reader.offset + 8 <= atom.end {
            try Task.checkCancellation()
            guard let child = try readAtom(from: &reader, end: atom.end, budget: &budget) else { return false }
            if isContainer(child.type) {
                guard try inspect(child, from: &reader, depth: depth + 1, budget: &budget) else { return false }
            }
            guard reader.seek(to: child.end) else { return false }
        }
        return reader.offset == atom.end
    }

    private static func inspectMetadataChildren(
        _ atom: AudioMetadataISOAtom,
        from reader: inout BoundedFileReader,
        depth: Int,
        budget: inout AudioMetadataBudget
    ) throws -> Bool {
        let headerBytes: UInt64 = atom.type == [0x6D, 0x65, 0x74, 0x61] ? 4 : 0
        guard atom.end - atom.dataStart >= headerBytes,
              reader.seek(to: atom.dataStart + headerBytes) else { return false }

        if atom.type == [0x69, 0x6C, 0x73, 0x74] {
            while reader.offset + 8 <= atom.end {
                try Task.checkCancellation()
                guard let child = try readAtom(from: &reader, end: atom.end, budget: &budget) else { return false }
                try budget.add(itemCount: 1)
                guard reader.seek(to: child.end) else { return false }
            }
            return reader.offset == atom.end
        }

        while reader.offset + 8 <= atom.end {
            try Task.checkCancellation()
            guard let child = try readAtom(from: &reader, end: atom.end, budget: &budget) else { return false }
            try budget.add(itemCount: 1)
            if isMetadataContainer(child.type) {
                guard depth <= AudioMetadataLimits.maximumMetadataContainerDepth,
                      try inspectMetadataChildren(
                          child,
                          from: &reader,
                          depth: depth + 1,
                          budget: &budget
                      ) else { return false }
            }
            guard reader.seek(to: child.end) else { return false }
        }
        return reader.offset == atom.end
    }

    private static func isMetadataContainer(_ type: [UInt8]) -> Bool {
        type == [0x75, 0x64, 0x74, 0x61] || type == [0x6D, 0x65, 0x74, 0x61] || type == [0x69, 0x6C, 0x73, 0x74]
    }

    private static func isTraversalContainer(_ type: [UInt8]) -> Bool {
        type == [0x6D, 0x6F, 0x6F, 0x76] || type == [0x74, 0x72, 0x61, 0x6B] || type == [0x6D, 0x64, 0x69, 0x61] ||
            type == [0x6D, 0x69, 0x6E, 0x66] || type == [0x73, 0x74, 0x62, 0x6C] || type == [0x64, 0x69, 0x6E, 0x66] ||
            type == [0x65, 0x64, 0x74, 0x73]
    }

    private static func isContainer(_ type: [UInt8]) -> Bool {
        isMetadataContainer(type) || isTraversalContainer(type)
    }

    private static func readAtom(
        from reader: inout BoundedFileReader,
        end: UInt64,
        budget: inout AudioMetadataBudget
    ) throws -> AudioMetadataISOAtom? {
        let start = reader.offset
        guard end >= start,
              end - start >= 8,
              let header = try reader.read(count: 8, budget: &budget),
              let shortSize = AudioMetadataBinarySupport.bigEndianUInt32(header, at: 0) else { return nil }
        var headerSize: UInt64 = 8
        let atomSize: UInt64
        if shortSize == 1 {
            guard let extendedData = try reader.read(count: 8, budget: &budget),
                  let extendedSize = AudioMetadataBinarySupport.bigEndianUInt64(extendedData, at: 0) else { return nil }
            headerSize = 16
            atomSize = extendedSize
        } else if shortSize == 0 {
            atomSize = end - start
        } else {
            atomSize = UInt64(shortSize)
        }
        guard atomSize >= headerSize, atomSize <= end - start else { return nil }
        return AudioMetadataISOAtom(
            type: Array(header[4..<8]),
            start: start,
            dataStart: start + headerSize,
            end: start + atomSize
        )
    }
}
