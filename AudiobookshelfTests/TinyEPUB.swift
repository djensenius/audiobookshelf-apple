import Foundation

/// A tiny EPUB 3 book, built in memory as an uncompressed ZIP, for the reader page's tests: one
/// chapter and a navigation document with one entry, "Chapter One".
enum TinyEPUB {
    static let chapterTitle = "Chapter One"

    static var data: Data {
        storedZIP([
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
                <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
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
        ])
    }

    /// A ZIP of `files`, in order, each stored without compression.
    private static func storedZIP(_ files: [(name: String, text: String)]) -> Data {
        var archive = Data()
        var directory = Data()
        for file in files {
            let name = Data(file.name.utf8)
            let body = Data(file.text.utf8)
            let offset = UInt32(archive.count)
            let shared = header(crc: crc32(body), size: UInt32(body.count), nameLength: UInt16(name.count))
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
        archive.append(contentsOf: [le16(0), le16(0), le16(UInt16(files.count)), le16(UInt16(files.count))].joined())
        archive.append(le32(UInt32(directory.count)))
        archive.append(le32(directoryOffset))
        archive.append(le16(0))  // comment length
        return archive
    }

    /// Flags, method (stored), time, date, CRC, sizes and name length: the part of a ZIP entry's
    /// local and central headers they share.
    private static func header(crc: UInt32, size: UInt32, nameLength: UInt16) -> Data {
        [le16(0), le16(0), le16(0), le16(0x21), le32(crc), le32(size), le32(size), le16(nameLength)].reduce(Data(), +)
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
