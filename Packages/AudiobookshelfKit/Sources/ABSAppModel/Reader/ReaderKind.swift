import ABSCore
import Foundation

/// Which reader opens an ebook file: the format router of ADR 0008.
///
/// EPUB uses the epub.js reader, PDF uses PDFKit and CBZ the comic pager. CBR, MOBI and AZW3 are
/// not opened in the app in v1 (ADR 0008 §4 and §5): the container shows the unsupported state
/// with "Open in…" and "Read in browser" instead. So does any format this client doesn't know.
public enum ReaderKind: Sendable, Hashable {
    case epub
    case pdf
    /// A comic archive. Only CBZ: CBR is ``unsupported(_:)``.
    case comic
    /// A format the app can't open, kept for the unsupported state's message.
    case unsupported(EbookFormat)

    public init(format: EbookFormat) {
        switch format {
        case .epub: self = .epub
        case .pdf: self = .pdf
        case .cbz: self = .comic
        case .cbr, .mobi, .azw3, .unknown: self = .unsupported(format)
        }
    }

    /// The reader for a file extension, with or without the leading dot, in any case.
    public init(fileExtension: String) {
        let trimmed = fileExtension.trimmingCharacters(in: .whitespaces)
        self.init(format: EbookFormat(rawValue: trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed))
    }

    /// The reader for a file, like the legacy `Reader.vue`: the server's `ebookFormat` when it
    /// sent one, otherwise the file's extension (supplementary ebooks have no `ebookFormat`).
    public init(format: EbookFormat?, fileExtension: String?) {
        if let format {
            self.init(format: format)
        } else {
            self.init(fileExtension: fileExtension ?? "")
        }
    }

    /// The reader for a book's primary ebook file.
    public init(_ file: EbookFile) {
        self.init(format: file.ebookFormat, fileExtension: Self.fileExtension(of: file.metadata))
    }

    /// The reader for a library file, such as a supplementary ebook.
    public init(_ file: LibraryFile) {
        self.init(format: nil, fileExtension: Self.fileExtension(of: file.metadata))
    }

    public var isSupported: Bool {
        if case .unsupported = self { false } else { true }
    }

    /// How this reader's `ebookLocation` is written; `nil` for an unsupported format, whose
    /// location is never read or saved (neither the legacy app nor the web client saves MOBI).
    public var locationStyle: EbookLocation.Style? {
        switch self {
        case .epub: .cfi
        case .pdf, .comic: .page
        case .unsupported: nil
        }
    }

    /// The server's `ext` (with its dot), or the filename's extension when it sent none.
    private static func fileExtension(of metadata: FileMetadata?) -> String? {
        guard let metadata else { return nil }
        return metadata.ext ?? (metadata.filename as NSString).pathExtension
    }
}
