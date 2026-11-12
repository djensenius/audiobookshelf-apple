import Foundation

/// A tiny EPUB 3 book, built in memory as a ZIP, for the reader page's tests: one chapter and a
/// navigation document with one entry, "Chapter One".
enum TinyEPUB {
    static let chapterTitle = "Chapter One"

    /// A file in the archive. `claimedSize` and `claimedCRC` are what its headers state (by
    /// default the truth); `deflated` compresses it rather than storing it.
    struct Entry {
        var name: String
        var body: Data
        var deflated = false
        var claimedSize: UInt32?
        var claimedCRC: UInt32?
    }

    static var data: Data { data() }

    /// The book, with `extra` entries after its own and `manifest` items after its own, and without
    /// its navigation document (though the package still lists it) when `navigation` is false.
    static func data(extra: [Entry] = [], manifest: String = "", navigation: Bool = true) -> Data {
        let files: [(name: String, text: String)] = [
            ("mimetype", "application/epub+zip"),
            (
                "META-INF/container.xml",
                """
                <?xml version="1.0"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """
            ),
            (
                "OEBPS/content.opf",
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
                <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="id">tiny</dc:identifier><dc:title>Tiny</dc:title><dc:language>en</dc:language>
                </metadata>
                <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>\(manifest)
                </manifest>
                <spine><itemref idref="c1"/></spine>
                </package>
                """
            ),
            (
                "OEBPS/nav.xhtml",
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Nav</title></head>
                <body><nav epub:type="toc"><ol><li><a href="c1.xhtml">\(chapterTitle)</a></li></ol></nav></body></html>
                """
            ),
            (
                "OEBPS/c1.xhtml",
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(chapterTitle)</title></head>
                <body><h1>\(chapterTitle)</h1><p>\(String(repeating: "Lorem ipsum dolor sit amet. ", count: 40))</p></body></html>
                """
            ),
        ]
        let entries =
            files.filter { navigation || $0.name != "OEBPS/nav.xhtml" }.map {
                Entry(name: $0.name, body: Data($0.text.utf8))
            }
            + extra
        return zip(entries)
    }

    /// The book ending in a ZIP64 end record whose extensible data has a length of -6, which steps
    /// JSZip 3.10.1's reader back onto the same field forever.
    static var loopingZIP64: Data {
        let book = data
        let end = book.count - 22
        func field(_ at: Int, _ size: Int) -> UInt64 {
            (0..<size).reduce(0) { $0 | UInt64(book[end + at + $1]) << (8 * $1) }
        }
        var archive = book.prefix(end)
        let record = UInt64(archive.count)
        archive.append(le32(0x0606_4b50))
        archive.append(le64(44 + 6))  // the record's size: its fixed fields, then the extensible data
        archive.append(contentsOf: [le16(45), le16(45), le32(0), le32(0)].joined())
        archive.append(
            contentsOf: [le64(field(10, 2)), le64(field(10, 2)), le64(field(12, 4)), le64(field(16, 4))].joined())
        archive.append(le16(1) + le32(0xFFFF_FFFA))  // an id, then the length -6
        archive.append(le32(0x0706_4b50) + le32(0) + le64(record) + le32(1))  // the ZIP64 locator
        archive.append(le32(0x0605_4b50))
        archive.append(contentsOf: [le16(0xFFFF), le16(0xFFFF), le16(0xFFFF), le16(0xFFFF)].joined())
        archive.append(le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF) + le16(0))
        return archive
    }

    /// An archive of one empty file whose `nameLength`-byte local name `count` directory entries
    /// share, each with a one-byte name of its own.
    static func sharingOneName(nameLength: Int, count: Int) -> Data {
        var archive = le32(0x0403_4b50) + le16(20)
        archive.append(header(method: 0, crc: 0, compressedSize: 0, size: 0, nameLength: UInt16(nameLength)))
        archive.append(le16(0) + Data(repeating: 0x61, count: nameLength))
        var directory = Data()
        for _ in 0..<count {
            directory.append(le32(0x0201_4b50) + le16(20) + le16(20))
            directory.append(header(method: 0, crc: 0, compressedSize: 0, size: 0, nameLength: 1))
            directory.append(contentsOf: [le16(0), le16(0), le16(0), le16(0), le32(0), le32(0)].joined())
            directory.append(0x61)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(contentsOf: [le32(0x0605_4b50), le16(0), le16(0)].joined())
        archive.append(le16(UInt16(count)) + le16(UInt16(count)) + le32(UInt32(directory.count)))
        archive.append(le32(directoryOffset) + le16(0))
        return archive
    }

    /// A ZIP of `entries`, in order.
    private static func zip(_ entries: [Entry]) -> Data {
        var archive = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            // Foundation's `.zlib` is raw DEFLATE, as ZIP's method 8 is.
            let body = entry.deflated ? try! (entry.body as NSData).compressed(using: .zlib) as Data : entry.body
            let offset = UInt32(archive.count)
            let shared = header(
                method: entry.deflated ? 8 : 0, crc: entry.claimedCRC ?? crc32(entry.body),
                compressedSize: UInt32(body.count),
                size: entry.claimedSize ?? UInt32(entry.body.count), nameLength: UInt16(name.count))
            archive.append(le32(0x0403_4b50))
            archive.append(le16(20))
            archive.append(shared)
            archive.append(le16(0))  // extra field length
            archive.append(name)
            archive.append(body)

            directory.append(le32(0x0201_4b50))
            directory.append(le16(20))  // made by
            directory.append(le16(20))  // needed to extract
            directory.append(shared)
            // Extra field, comment, disk number and internal attributes.
            directory.append(contentsOf: [le16(0), le16(0), le16(0), le16(0)].joined())
            directory.append(le32(0))  // external attributes
            directory.append(le32(offset))
            directory.append(name)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(le32(0x0605_4b50))
        archive.append(
            contentsOf: [le16(0), le16(0), le16(UInt16(entries.count)), le16(UInt16(entries.count))].joined())
        archive.append(le32(UInt32(directory.count)))
        archive.append(le32(directoryOffset))
        archive.append(le16(0))  // comment length
        return archive
    }

    /// Flags, method, time, date, CRC, sizes and name length: the part of a ZIP entry's local and
    /// central headers they share.
    private static func header(
        method: UInt16, crc: UInt32, compressedSize: UInt32, size: UInt32, nameLength: UInt16
    ) -> Data {
        [
            le16(0), le16(method), le16(0), le16(0x21), le32(crc), le32(compressedSize), le32(size),
            le16(nameLength),
        ].reduce(Data(), +)
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
