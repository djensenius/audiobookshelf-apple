import Foundation

/// Where one library item's downloaded files go, as paths relative to
/// ``DownloadLocations/downloadsRoot``. Pure: it touches no files.
///
/// - Item folder: `<connectionID>/<libraryItemID>/`, so two servers' items with the same ID
///   never share a folder.
/// - Book files: `<folder>/<filename>`.
/// - Podcast episode files: `<folder>/episodes/<episodeID>/<filename>`.
/// - Cover: `<folder>/cover.jpg`.
///
/// IDs are escaped losslessly, so different IDs always get different folders. Filenames come
/// from the server and are cleaned (see ``sanitisedFilename(_:suffix:)``). Names that clash in
/// one folder, such as `01.mp3` from two disc folders, get ` (2)`, ` (3)` and so on before the
/// extension, ignoring case because the Mac's default volume does. Every path is checked with
/// ``DownloadLocations/fileURL(forRelativePath:)``.
public struct DownloadLayout: Sendable {
    /// Why a path can't be built.
    public enum LayoutError: Error, Equatable {
        /// An ID is empty, or too long for one path component once escaped.
        case invalidIdentifier(String)
    }

    /// The most UTF-8 bytes in one path component (the APFS limit).
    public static let maxComponentBytes = 255
    /// The cover's name in the item folder.
    public static let coverFilename = "cover.jpg"
    /// The item-folder subfolder that holds one folder per episode.
    public static let episodesFolder = "episodes"

    /// The item folder, `<connectionID>/<libraryItemID>`, without a trailing slash.
    public let folder: String
    private let locations: DownloadLocations
    /// Lowercased names already given out, by the folder they are in.
    private var usedNames: [String: Set<String>]

    /// - Throws: ``LayoutError/invalidIdentifier(_:)`` if `libraryItemID` is empty or too long.
    public init(connectionID: UUID, libraryItemID: String, locations: DownloadLocations) throws {
        folder = "\(connectionID.uuidString)/\(try Self.escapedIdentifier(libraryItemID))"
        self.locations = locations
        // The cover and the episodes folder share the item folder with book files.
        usedNames = [folder: [Self.coverFilename, Self.episodesFolder]]
        _ = try locations.fileURL(forRelativePath: folder)
    }

    /// The cover's path, `<folder>/cover.jpg`.
    public func coverPath() throws -> String {
        try checked("\(folder)/\(Self.coverFilename)")
    }

    /// A new, unused path for a book file named `filename`: `<folder>/<filename>`.
    public mutating func bookFilePath(filename: String) throws -> String {
        try reservePath(in: folder, filename: filename)
    }

    /// A new, unused path for a podcast episode's file named `filename`:
    /// `<folder>/episodes/<episodeID>/<filename>`.
    ///
    /// - Throws: ``LayoutError/invalidIdentifier(_:)`` if `episodeID` is empty or too long.
    public mutating func episodeFilePath(episodeID: String, filename: String) throws -> String {
        let directory = "\(folder)/\(Self.episodesFolder)/\(try Self.escapedIdentifier(episodeID))"
        return try reservePath(in: directory, filename: filename)
    }

    private mutating func reservePath(in directory: String, filename: String) throws -> String {
        let name = Self.sanitisedFilename(filename)
        var used = usedNames[directory, default: []]
        var candidate = name
        var number = 2
        while used.contains(candidate.lowercased()) {
            candidate = Self.sanitisedFilename(name, suffix: " (\(number))")
            number += 1
        }
        let path = try checked("\(directory)/\(candidate)")
        used.insert(candidate.lowercased())
        usedNames[directory] = used
        return path
    }

    private func checked(_ path: String) throws -> String {
        _ = try locations.fileURL(forRelativePath: path)
        return path
    }

    // MARK: - Names

    /// `filename` as one safe path component: `/`, `\`, `:` and control characters become `_`,
    /// leading dots are dropped (so it is never `.`, `..` or hidden), and it is shortened to
    /// ``maxComponentBytes`` UTF-8 bytes, keeping the extension and never splitting a
    /// character. An empty result becomes `file`.
    ///
    /// - Parameter suffix: text put before the extension, such as ` (2)`; the stem is shortened
    ///   to make room for it.
    public static func sanitisedFilename(_ filename: String, suffix: String = "") -> String {
        let scalars = filename.unicodeScalars.map { scalar -> Unicode.Scalar in
            let unsafe = scalar == "/" || scalar == "\\" || scalar == ":"
            return unsafe || scalar.properties.generalCategory == .control ? "_" : scalar
        }
        var cleaned = String(String.UnicodeScalarView(scalars))
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "file" }

        var stem = cleaned
        var fileExtension = ""
        // The extension is the text after the last dot, if it is short; a long one stays in the stem.
        if let dot = cleaned.lastIndex(of: "."), cleaned.utf8[cleaned.index(after: dot)...].count <= 32 {
            stem = String(cleaned[..<dot])
            fileExtension = String(cleaned[dot...])
        }
        let tail = suffix + fileExtension
        while !stem.isEmpty, stem.utf8.count + tail.utf8.count > maxComponentBytes {
            stem.removeLast()
        }
        if stem.isEmpty { stem = "file" }
        return stem + tail
    }

    /// `id` escaped into one path component without losing information: anything but ASCII
    /// letters, digits, `-`, `_` and a non-leading `.` becomes `%XX`.
    static func escapedIdentifier(_ id: String) throws -> String {
        var escaped = id.addingPercentEncoding(withAllowedCharacters: identifierCharacters) ?? ""
        if escaped.hasPrefix(".") { escaped = "%2E" + escaped.dropFirst() }
        guard !escaped.isEmpty, escaped.utf8.count <= maxComponentBytes else { throw LayoutError.invalidIdentifier(id) }
        return escaped
    }

    private static let identifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
}
