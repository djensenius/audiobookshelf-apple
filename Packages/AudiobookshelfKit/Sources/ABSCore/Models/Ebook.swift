import Foundation

public enum EbookFormat: Sendable, Hashable, Codable, RawRepresentable {
    case epub
    case pdf
    case mobi
    case azw3
    case cbr
    case cbz
    /// A format this client doesn't know; the server's value is kept.
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "epub": self = .epub
        case "pdf": self = .pdf
        case "mobi": self = .mobi
        case "azw3": self = .azw3
        case "cbr": self = .cbr
        case "cbz": self = .cbz
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .epub: "epub"
        case .pdf: "pdf"
        case .mobi: "mobi"
        case .azw3: "azw3"
        case .cbr: "cbr"
        case .cbz: "cbz"
        case .unknown(let value): value
        }
    }

    public var mimeType: String? {
        switch self {
        case .epub: "application/epub+zip"
        case .pdf: "application/pdf"
        case .mobi: "application/x-mobipocket-ebook"
        case .azw3: "application/vnd.amazon.mobi8-ebook"
        case .cbr: "application/vnd.comicbook-rar"
        case .cbz: "application/vnd.comicbook+zip"
        case .unknown: nil
        }
    }
}

public struct EbookFile: Sendable, Hashable, Codable, Identifiable {
    public let ino: String
    public let metadata: FileMetadata?
    public let ebookFormat: EbookFormat?
    /// Epoch milliseconds.
    public let addedAt: Int?
    /// Epoch milliseconds.
    public let updatedAt: Int?

    public init(
        ino: String, metadata: FileMetadata? = nil, ebookFormat: EbookFormat? = nil, addedAt: Int? = nil,
        updatedAt: Int? = nil
    ) {
        self.ino = ino
        self.metadata = metadata
        self.ebookFormat = ebookFormat
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }

    public var id: String { ino }

    private enum CodingKeys: String, CodingKey {
        case ino, metadata, ebookFormat, addedAt, updatedAt
    }

    /// Legacy servers can send `ino: null` (or none); that's `""` rather than failing the whole
    /// item. Nothing addresses the primary ebook by it except a download, which refuses a blank one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ino = try container.decodeIfPresent(String.self, forKey: .ino) ?? ""
        metadata = try container.decodeIfPresent(FileMetadata.self, forKey: .metadata)
        ebookFormat = try container.decodeIfPresent(EbookFormat.self, forKey: .ebookFormat)
        addedAt = try container.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
    }
}
