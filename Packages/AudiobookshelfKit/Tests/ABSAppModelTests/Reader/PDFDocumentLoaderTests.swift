import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import ABSAppModel

@Suite struct PDFDocumentLoaderTests {
    @Test func opensAPDF() async throws {
        let url = try writePDF(pages: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await PDFDocumentLoader.load(from: url)
        #expect(document.pageCount == 3)
    }

    @Test func missingFileIsNotFound() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        await #expect(throws: PDFDocumentLoadError.fileNotFound) { try await PDFDocumentLoader.load(from: url) }
    }

    @Test func remoteURLIsNotFound() async {
        let url = URL(string: "https://abs.example.com/api/items/li_1/ebook")!
        await #expect(throws: PDFDocumentLoadError.fileNotFound) { try await PDFDocumentLoader.load(from: url) }
    }

    @Test(arguments: [Data("not a pdf".utf8), Data(), Data("%PDF-1.7\n%%EOF".utf8)])
    func corruptFileIsUnreadable(bytes: Data) async throws {
        let url = try write(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: PDFDocumentLoadError.unreadable) { try await PDFDocumentLoader.load(from: url) }
    }

    @Test func encryptedPDFWithoutAPasswordIsLocked() async throws {
        let url = try writePDF(pages: 2, password: "secret")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: PDFDocumentLoadError.locked) { try await PDFDocumentLoader.load(from: url) }
        await #expect(throws: PDFDocumentLoadError.locked) {
            try await PDFDocumentLoader.load(from: url, password: "wrong")
        }
    }

    @Test func encryptedPDFOpensWithItsPassword() async throws {
        let url = try writePDF(pages: 2, password: "secret")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await PDFDocumentLoader.load(from: url, password: "secret")
        #expect(document.pageCount == 2 && !document.isLocked)
    }

    @Test func pdfWithoutPagesIsUnreadable() async throws {
        let url = try write(pagelessPDF())
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: PDFDocumentLoadError.unreadable) { try await PDFDocumentLoader.load(from: url) }
    }

    @Test func pageNumbersAreOneBased() throws {
        let document = try #require(PDFDocument(data: pdfData(pages: 3)))
        let numbers = (0..<3).map { document.page(at: $0).flatMap(document.oneBasedPageNumber(of:)) }
        #expect(numbers == [1, 2, 3])

        let other = try #require(PDFDocument(data: pdfData(pages: 1))?.page(at: 0))
        #expect(document.oneBasedPageNumber(of: other) == nil)
    }

    @Test func oneBasedPagesAreClampedToTheDocument() throws {
        let document = try #require(PDFDocument(data: pdfData(pages: 3)))
        let index = { (number: Int) in document.page(oneBased: number).map(document.index(for:)) }
        #expect(index(1) == 0)
        #expect(index(3) == 2)
        #expect(index(0) == 0)
        #expect(index(-4) == 0)
        #expect(index(9) == 2)
        #expect(PDFDocument().page(oneBased: 1) == nil)
    }
}

private func write(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
    try data.write(to: url)
    return url
}

private func writePDF(pages: Int, password: String? = nil) throws -> URL {
    try write(pdfData(pages: pages, password: password))
}

/// A well-formed PDF whose page tree is empty. Core Graphics can't write one: it adds a blank page.
private func pagelessPDF() -> Data {
    var text = "%PDF-1.4\n"
    var offsets: [Int] = []
    for object in ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>"] {
        offsets.append(text.utf8.count)
        text += "\(offsets.count) 0 obj\n\(object)\nendobj\n"
    }
    let xref = text.utf8.count
    text += "xref\n0 3\n0000000000 65535 f \n"
    for offset in offsets { text += String(format: "%010d 00000 n \n", offset) }
    text += "trailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(text.utf8)
}

/// A PDF drawn in code, so no binary fixture is committed.
private func pdfData(pages: Int, password: String? = nil) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    var info: [CFString: Any] = [:]
    if let password {
        info[kCGPDFContextUserPassword] = password
        info[kCGPDFContextOwnerPassword] = password + "-owner"
    }
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
        let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary)
    else { return Data() }
    for page in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: CGFloat(page) / CGFloat(max(pages, 1)), alpha: 1))
        context.fill(box.insetBy(dx: 20, dy: 20))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}
