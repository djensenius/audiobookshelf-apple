import Foundation
import PDFKit

/// Why a PDF can't be opened, for the reader's "can't open" state.
public enum PDFDocumentLoadError: Error, Sendable, Hashable {
    /// No file at the URL, or the URL isn't a file URL.
    case fileNotFound
    /// PDFKit can't read the file: it's corrupt, not a PDF, or has no pages.
    case unreadable
    /// The PDF is encrypted, and no password, or the wrong one, was given.
    case locked
}

/// Opens a downloaded PDF for the app's PDFKit reader (ADR 0008, decision 2).
public enum PDFDocumentLoader {
    /// Opens the PDF at a local file URL, off the main actor, because PDFKit reads and parses
    /// the file as it opens it.
    /// - Parameter password: Unlocks an encrypted PDF. A PDF that's encrypted with only an
    ///   owner password opens without one.
    @concurrent
    public static func load(from url: URL, password: String? = nil) async throws(PDFDocumentLoadError)
        -> sending PDFDocument
    {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else {
            throw .fileNotFound
        }
        guard let document = PDFDocument(url: url) else { throw .unreadable }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password) else { throw .locked }
        }
        // PDFKit already refuses a PDF without pages; this keeps a reader from opening on none.
        guard document.pageCount > 0 else { throw .unreadable }
        return document
    }
}

extension PDFDocument {
    /// A page's 1-based number, the form `ebookLocation` stores (PDFKit's index + 1), or `nil` for a
    /// page from another document.
    public func oneBasedPageNumber(of page: PDFPage) -> Int? {
        let index = index(for: page)
        guard index != NSNotFound, (0..<pageCount).contains(index) else { return nil }
        return index + 1
    }

    /// The page with a 1-based number, clamped to the document, or `nil` when it has no pages.
    public func page(oneBased number: Int) -> PDFPage? {
        guard pageCount > 0 else { return nil }
        return page(at: min(max(number, 1), pageCount) - 1)
    }
}
