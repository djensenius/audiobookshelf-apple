import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

@Suite struct ReaderKindTests {
    static let formats: [(EbookFormat, ReaderKind)] = [
        (.epub, .epub),
        (.pdf, .pdf),
        (.cbz, .comic),
        // ADR 0008 §4 and §5: not opened in the app in v1.
        (.cbr, .unsupported(.cbr)),
        (.mobi, .unsupported(.mobi)),
        (.azw3, .unsupported(.azw3)),
        (.unknown("djvu"), .unsupported(.unknown("djvu"))),
    ]

    @Test(arguments: formats)
    func routesFormat(_ format: EbookFormat, _ expected: ReaderKind) {
        #expect(ReaderKind(format: format) == expected)
        #expect(ReaderKind(format: format).isSupported == [.epub, .pdf, .cbz].contains(format))
    }

    static let extensions: [(String, ReaderKind)] = [
        (".epub", .epub),
        ("epub", .epub),
        (".PDF", .pdf),
        (" .cbz ", .comic),
        (".CBR", .unsupported(.cbr)),
        (".mobi", .unsupported(.mobi)),
        (".azw3", .unsupported(.azw3)),
        (".txt", .unsupported(.unknown("txt"))),
        ("", .unsupported(.unknown(""))),
    ]

    @Test(arguments: extensions)
    func routesFileExtension(_ fileExtension: String, _ expected: ReaderKind) {
        #expect(ReaderKind(fileExtension: fileExtension) == expected)
    }

    /// Like the legacy `Reader.vue`: the server's format wins, the extension is the fallback.
    @Test func prefersTheServerFormat() {
        #expect(ReaderKind(format: .pdf, fileExtension: ".epub") == .pdf)
        #expect(ReaderKind(format: nil, fileExtension: ".epub") == .epub)
        #expect(ReaderKind(format: nil, fileExtension: nil) == .unsupported(.unknown("")))

        let primary = EbookFile(
            ino: "1", metadata: FileMetadata(filename: "book.epub", ext: ".epub", path: "/b/book.epub"),
            ebookFormat: .cbz)
        #expect(ReaderKind(primary) == .comic)
        let untyped = EbookFile(ino: "2", metadata: FileMetadata(filename: "Book.PDF", path: "/b/Book.PDF"))
        #expect(ReaderKind(untyped) == .pdf)
        let supplementary = LibraryFile(
            ino: "3", metadata: FileMetadata(filename: "extra.cbr", ext: ".cbr", path: "/b/extra.cbr"),
            isSupplementary: true, fileType: "ebook")
        #expect(ReaderKind(supplementary) == .unsupported(.cbr))
    }

    @Test func locationStyles() {
        #expect(ReaderKind.epub.locationStyle == .cfi)
        #expect(ReaderKind.pdf.locationStyle == .page)
        #expect(ReaderKind.comic.locationStyle == .page)
        #expect(ReaderKind.unsupported(.mobi).locationStyle == nil)
    }
}

@Suite struct EbookLocationTests {
    static let parsed: [(String?, EbookLocation.Style?, EbookLocation?)] = [
        ("epubcfi(/6/6!/4/40[c3p19]/1:747)", .cfi, .cfi("epubcfi(/6/6!/4/40[c3p19]/1:747)")),
        // The legacy app and the web client check only the prefix.
        ("epubcfi", .cfi, .cfi("epubcfi")),
        ("EPUBCFI(/6/2)", .cfi, nil),
        (" epubcfi(/6/2)", .cfi, nil),
        ("12", .cfi, nil),
        ("", .cfi, nil),
        (nil, .cfi, nil),
        ("1", .page, .page(1)),
        ("42", .page, .page(42)),
        (" 7\n", .page, .page(7)),
        ("3.0", .page, .page(3)),
        ("0", .page, nil),
        ("-2", .page, nil),
        ("2.5", .page, nil),
        ("", .page, nil),
        ("abc", .page, nil),
        ("nan", .page, nil),
        ("inf", .page, nil),
        ("1e100", .page, nil),
        ("epubcfi(/6/2)", .page, nil),
        (nil, .page, nil),
        // Unsupported formats never read a location.
        ("3", nil, nil),
        ("epubcfi(/6/2)", nil, nil),
    ]

    @Test(arguments: parsed)
    func parsesStoredLocation(_ stored: String?, _ style: EbookLocation.Style?, _ expected: EbookLocation?) {
        #expect(EbookLocation(stored, style: style) == expected)
    }

    /// The web client sends a page as a JSON number.
    @Test func parsesNumericPages() {
        #expect(EbookLocation(page: 5, style: .page) == .page(5))
        #expect(EbookLocation(page: 0, style: .page) == nil)
        #expect(EbookLocation(page: 1.5, style: .page) == nil)
        #expect(EbookLocation(page: .nan, style: .page) == nil)
        #expect(EbookLocation(page: 5, style: .cfi) == nil)
        #expect(EbookLocation(page: 5, style: nil) == nil)
    }

    @Test func storedValuesRoundTrip() {
        #expect(EbookLocation.page(12).stored == "12")
        #expect(EbookLocation.cfi("epubcfi(/6/2)").stored == "epubcfi(/6/2)")
        #expect(EbookLocation.page(12).isValid(for: .pdf))
        #expect(EbookLocation.page(12).isValid(for: .comic))
        #expect(!EbookLocation.page(12).isValid(for: .epub))
        #expect(!EbookLocation.page(0).isValid(for: .pdf))
        #expect(!EbookLocation.cfi("chapter1.xhtml").isValid(for: .epub))
        #expect(!EbookLocation.cfi("epubcfi(/6/2)").isValid(for: .unsupported(.mobi)))
    }

    /// Legacy PDF and comic readers open a saved page only when the document has it.
    @Test func startPageIsWithinTheDocument() {
        #expect(EbookLocation.page(4).startPage(pageCount: 10) == 4)
        #expect(EbookLocation.page(10).startPage(pageCount: 10) == 10)
        #expect(EbookLocation.page(11).startPage(pageCount: 10) == 1)
        #expect(EbookLocation.page(0).startPage(pageCount: 10) == 1)
        #expect(EbookLocation.page(-3).startPage(pageCount: 10) == 1)
        #expect(EbookLocation.cfi("epubcfi(/6/2)").startPage(pageCount: 10) == 1)
    }

    @Test func pageProgressUsesTheWebFormula() {
        #expect(EbookLocation.progress(page: 1, pageCount: 4) == 0)
        #expect(EbookLocation.progress(page: 3, pageCount: 4) == 0.5)
        #expect(EbookLocation.progress(page: 4, pageCount: 4) == 0.75)
        #expect(EbookLocation.progress(page: 9, pageCount: 4) == 1)
        #expect(EbookLocation.progress(page: 1, pageCount: 0) == 0)
    }
}
