import Foundation

/// Checks a ZIP's structure before ZIPFoundation 0.9.20 opens it. ZIPFoundation trusts the
/// structure: it scans the whole file backwards for the end record, converts offsets and sizes to
/// `Int64` unchecked (which traps), and adds data-descriptor positions unchecked (which overflows).
///
/// The end record must be in the last 65,557 bytes: its 22 bytes and the longest comment. The
/// central directory is then walked the way ZIPFoundation walks it, using the ZIP64 end record and
/// extra fields where ZIPFoundation does. Every record's local header and data must lie in the
/// file: the compressed data, and the uncompressed size too when stored, which is what
/// ZIPFoundation reads. That also bounds the data-descriptor position. A malformed ZIP64 field
/// leaves ZIPFoundation with the `0xFFFFFFFF` placeholder, which is checked like any other value.
///
/// ZIPFoundation's entries keep their headers (path, extra field, comment, and the local header's
/// path and extra field, read again for every record that shares it). Those must total at most
/// ``maxHeaderBytes``, so the entries can be kept.
enum ComicArchivePreflight {
    static let maxTrailerBytes = 22 + 0xFFFF
    static let maxHeaderBytes = 16 << 20

    static func validate(
        _ url: URL, maxEntries: Int, maxHeaderBytes: Int = maxHeaderBytes
    ) throws(ComicArchiveError) {
        guard let handle = try? FileHandle(forReadingFrom: url), let length = try? handle.seekToEnd() else {
            throw .notAZip
        }
        defer { try? handle.close() }
        let file = File(handle: handle, length: length)
        guard let end = file.endOfCentralDirectory() else { throw .notAZip }
        guard end.count <= UInt64(maxEntries) else { throw .tooManyEntries }
        var position = end.offset
        var headerBytes = 0
        for _ in 0..<end.count {
            guard let record = file.bytes(at: position, count: 46), record.uint32(at: 0) == 0x0201_4B50 else {
                throw .notAZip
            }
            let lengths = [28, 30, 32].map { Int(record.uint16(at: $0)) }
            let extraOffset = position + 46 + UInt64(lengths[0])
            guard let extra = file.bytes(at: extraOffset, count: lengths[1]),
                file.contains(extraOffset + UInt64(lengths[1] + lengths[2]))
            else { throw .notAZip }
            let sizes = Sizes(record: record, extra: extra)
            guard let local = file.bytes(at: sizes.localOffset, count: 30), local.uint32(at: 0) == 0x0403_4B50 else {
                throw .notAZip
            }
            let localLengths = Int(local.uint16(at: 26)) + Int(local.uint16(at: 28))
            let dataOffset = sizes.localOffset + 30 + UInt64(localLengths)
            let isStored = record.uint16(at: 10) == 0 || local.uint16(at: 8) == 0
            guard file.contains(dataOffset, plus: sizes.compressed),
                !isStored || file.contains(dataOffset, plus: sizes.uncompressed)
            else { throw .notAZip }
            headerBytes += lengths.reduce(0, +) + localLengths
            guard headerBytes <= maxHeaderBytes else { throw .tooManyEntries }
            position = extraOffset + UInt64(lengths[1] + lengths[2])
        }
    }

    private struct File {
        let handle: FileHandle
        let length: UInt64

        func contains(_ offset: UInt64, plus count: UInt64 = 0) -> Bool {
            let (end, overflow) = offset.addingReportingOverflow(count)
            return !overflow && end <= length
        }

        /// `count` bytes at `offset`; `nil` unless they're all in the file.
        func bytes(at offset: UInt64, count: Int) -> Data? {
            guard contains(offset, plus: UInt64(count)) else { return nil }
            guard count > 0 else { return Data() }
            guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count),
                data.count == count
            else { return nil }
            return Data(data)
        }

        /// The entry count and directory offset ZIPFoundation uses. It takes the last end-record
        /// signature, so a search of the trailer from its end finds the same one, or none.
        func endOfCentralDirectory() -> (count: UInt64, offset: UInt64)? {
            let trailerLength = min(length, UInt64(maxTrailerBytes))
            guard trailerLength >= 22, let trailer = bytes(at: length - trailerLength, count: Int(trailerLength)),
                let index = stride(from: trailer.count - 22, through: 0, by: -1).first(where: {
                    trailer.uint32(at: $0) == 0x0605_4B50
                })
            else { return nil }
            let offset = length - trailerLength + UInt64(index)
            // ZIPFoundation reads the ZIP64 locator and record just before the end record.
            if offset > 20 + 56, let locator = bytes(at: offset - 20, count: 20),
                locator.uint32(at: 0) == 0x0706_4B50, let record = bytes(at: offset - 76, count: 56),
                record.uint32(at: 0) == 0x0606_4B50, record.uint16(at: 14) >= 45
            {
                return (record.uint64(at: 32), record.uint64(at: 48))
            }
            return (UInt64(trailer.uint16(at: index + 10)), UInt64(trailer.uint32(at: index + 16)))
        }
    }

    /// A central-directory record's sizes and local-header offset, as ZIPFoundation's `effective…`
    /// properties read them.
    private struct Sizes {
        var compressed: UInt64
        var uncompressed: UInt64
        var localOffset: UInt64

        init(record: Data, extra: Data) {
            compressed = UInt64(record.uint32(at: 20))
            uncompressed = UInt64(record.uint32(at: 24))
            localOffset = UInt64(record.uint32(at: 42))
            var fields: [Int] = []
            if uncompressed == UInt32.max { fields.append(8) }
            if compressed == UInt32.max { fields.append(8) }
            if localOffset == UInt32.max { fields.append(8) }
            if record.uint16(at: 34) == .max { fields.append(4) }
            let zip64 = Self.zip64Field(in: extra, size: fields.reduce(0, +))
            guard UInt8(truncatingIfNeeded: record.uint16(at: 6)) >= 45 || zip64 != nil else { return }
            var offset = 4
            func next(_ marked: Bool) -> UInt64 {
                guard let zip64, marked else { return 0 }
                defer { offset += 8 }
                return zip64.uint64(at: offset)
            }
            let zip64Uncompressed = next(uncompressed == UInt32.max)
            let zip64Compressed = next(compressed == UInt32.max)
            let zip64Offset = next(localOffset == UInt32.max)
            if zip64Uncompressed > 0 { uncompressed = zip64Uncompressed }
            if zip64Compressed > 0 { compressed = zip64Compressed }
            if zip64Offset > 0 { localOffset = zip64Offset }
        }

        /// ZIPFoundation's ZIP64 field: the first field with ID 1, if its size matches the
        /// placeholders. The search stops at a field that overruns the extra field.
        private static func zip64Field(in extra: Data, size: Int) -> Data? {
            var offset = 0
            while offset < extra.count - 4 {
                let id = extra.uint16(at: offset)
                let next = offset + 4 + Int(extra.uint16(at: offset + 2))
                guard next <= extra.count else { return nil }
                if id == 1 { return next - offset == size + 4 ? extra.subdata(in: offset..<next) : nil }
                offset = next
            }
            return nil
        }
    }
}

extension Data {
    fileprivate func uint16(at offset: Int) -> UInt16 { littleEndian(at: offset) }
    fileprivate func uint32(at offset: Int) -> UInt32 { littleEndian(at: offset) }
    fileprivate func uint64(at offset: Int) -> UInt64 { littleEndian(at: offset) }

    private func littleEndian<T: FixedWidthInteger>(at offset: Int) -> T {
        (0..<MemoryLayout<T>.size).reduce(T.zero) { value, byte in
            value | T(self[startIndex + offset + byte]) << (byte * 8)
        }
    }
}
