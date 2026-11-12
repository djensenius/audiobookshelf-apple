import Foundation

/// A comic archive's container, from its first bytes rather than its extension: `.cbz` files are
/// sometimes RAR archives and `.cbr` files ZIP archives.
///
/// Only ZIP opens in the app (``ComicArchive``). RAR (CBR) gets the unsupported state, "This
/// format can't be opened in the app", in v1 (ADR 0008 §4).
public enum ComicArchiveFormat: Sendable, Hashable {
    case zip
    case rar
    /// Neither ZIP nor RAR, or too short to tell.
    case unknown

    /// Whether ``ComicArchive`` can open it.
    public var canOpen: Bool { self == .zip }

    /// The format of the file at `url`, read from its signature.
    public init(contentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        self.init(signature: try handle.read(upToCount: 8) ?? Data())
    }

    /// The format whose signature starts `bytes`: `PK\3\4` (or `PK\5\6` for an empty archive)
    /// for ZIP, `Rar!\x1A\x07` for RAR 4 and 5.
    public init(signature bytes: some Collection<UInt8>) {
        let bytes = Array(bytes.prefix(8))
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) || bytes.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            self = .zip
        } else if bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) {
            self = .rar
        } else {
            self = .unknown
        }
    }
}
