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
/// IDs are escaped losslessly and case-safely, so different IDs always get different folders,
/// even on a case-insensitive volume. Filenames come from the server and are cleaned (see
/// ``sanitisedFilename(_:)``). Names that clash in one folder, such as `01.mp3` from two
/// disc folders, get ` (2)`, ` (3)` and so on before the extension. Clashes are found with
/// case folding (`Straße` and `STRASSE` clash), because the Mac's default volume ignores case.
/// Every path is checked with ``DownloadLocations/fileURL(forRelativePath:)``.
///
/// Clashes are only found among names this value knows: plan all of an item's new files
/// through one value, in the server's stable order, and pass the paths of files already
/// stored for the item to ``init(connectionID:libraryItemID:locations:reserving:)`` so a new
/// file never takes an existing file's path.
///
/// Each component is at most ``maxComponentBytes``, but the whole path isn't capped (`PATH_MAX`
/// is 1024 bytes); real connection, item and episode IDs are short, so it stays well under.
public struct DownloadLayout: Sendable {
    /// Why a path can't be built.
    public enum LayoutError: Error, Equatable {
        /// An ID is empty, or too long for one path component once escaped.
        case invalidIdentifier(String)
        /// A path to reserve isn't a file this type would place in the item's folder.
        case unrelatedPath(String)
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
    /// The ``collisionKey(_:)`` of each name already given out, by the folder it is in.
    private var usedNames: [String: Set<String>]

    /// A layout for an item with no files stored yet.
    ///
    /// - Throws: ``LayoutError/invalidIdentifier(_:)`` if `libraryItemID` is empty or too long.
    public init(connectionID: UUID, libraryItemID: String, locations: DownloadLocations) throws {
        try self.init(
            connectionID: connectionID, libraryItemID: libraryItemID, locations: locations, reserving: [String]())
    }

    /// A layout for an item that already has files stored at `existingPaths`, which are paths
    /// this type returned before for the same connection and item. New files never get one of
    /// those paths, or one that clashes with it.
    ///
    /// - Throws: ``LayoutError/invalidIdentifier(_:)`` if `libraryItemID` is empty or too long,
    ///   or ``LayoutError/unrelatedPath(_:)`` if a path isn't a book file, episode file or cover
    ///   directly in this item's folder layout.
    public init(
        connectionID: UUID, libraryItemID: String, locations: DownloadLocations,
        reserving existingPaths: some Sequence<String>
    ) throws {
        folder = "\(connectionID.uuidString)/\(try Self.escapedIdentifier(libraryItemID))"
        self.locations = locations
        // The cover and the episodes folder share the item folder with book files.
        usedNames = [folder: [Self.collisionKey(Self.coverFilename), Self.collisionKey(Self.episodesFolder)]]
        _ = try locations.fileURL(forRelativePath: folder)
        for path in existingPaths {
            try reserveExisting(path)
        }
    }

    private mutating func reserveExisting(_ path: String) throws {
        _ = try locations.fileURL(forRelativePath: path)
        // Split on scalars, not Characters: a `/` followed by a combining mark is still a separator.
        let prefix = (folder + "/").unicodeScalars
        guard path.unicodeScalars.starts(with: prefix) else { throw LayoutError.unrelatedPath(path) }
        let components = path.unicodeScalars.dropFirst(prefix.count)
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        let directory: String
        switch components.count {
        case 1:
            directory = folder
        case 3 where components[0] == Self.episodesFolder:
            directory = "\(folder)/\(Self.episodesFolder)/\(components[1])"
        default:
            throw LayoutError.unrelatedPath(path)
        }
        usedNames[directory, default: []].insert(Self.collisionKey(components[components.count - 1]))
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
        while used.contains(Self.collisionKey(candidate)) {
            candidate = Self.numberedFilename(name, number: number)
            number += 1
        }
        let path = try checked("\(directory)/\(candidate)")
        used.insert(Self.collisionKey(candidate))
        usedNames[directory] = used
        return path
    }

    private func checked(_ path: String) throws -> String {
        _ = try locations.fileURL(forRelativePath: path)
        return path
    }

    // MARK: - Names

    /// The form in which two names clash on a case-insensitive volume. Canonically equivalent
    /// strings (NFC and NFD) are already equal as Swift strings.
    static func collisionKey(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: nil)
    }

    /// `filename` as one safe path component: `/`, `\`, `:`, control and format characters
    /// (such as U+202E RIGHT-TO-LEFT OVERRIDE, U+200B and U+FEFF) and line and paragraph
    /// separators become `_` (zero-width joiners and non-joiners are kept), leading dots are
    /// dropped (so it is never `.`, `..` or hidden, even when a combining mark follows the dot),
    /// and it is shortened to ``maxComponentBytes`` UTF-8 bytes, keeping the extension and never
    /// splitting a character. An empty result becomes `file`.
    public static func sanitisedFilename(_ filename: String) -> String {
        sanitised(filename, suffix: "")
    }

    /// The sanitised `name` with ` (number)` before its extension, shortened to fit.
    static func numberedFilename(_ name: String, number: Int) -> String {
        sanitised(name, suffix: " (\(number))")
    }

    /// `suffix` is only ever ` (n)`, short and safe; the stem is shortened to make room for it.
    private static func sanitised(_ filename: String, suffix: String) -> String {
        var scalars = filename.unicodeScalars.map { scalar -> Unicode.Scalar in
            let unsafe = scalar == "/" || scalar == "\\" || scalar == ":"
            switch scalar.properties.generalCategory {
            // Zero-width (non-)joiners are format characters too, but emoji and scripts need them.
            case .format where scalar == "\u{200C}" || scalar == "\u{200D}": return scalar
            case .control, .format, .lineSeparator, .paragraphSeparator: return "_"
            default: return unsafe ? "_" : scalar
            }
        }
        // Scalars, not Characters: `.` plus a combining mark is one Character but still hides a file.
        scalars.removeFirst(scalars.prefix { $0 == "." }.count)
        var cleaned = String(String.UnicodeScalarView(scalars))
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

    /// `id` escaped into one path component without losing information, even on a
    /// case-insensitive volume: anything but lowercase ASCII letters, digits, `-`, `_` and a
    /// non-leading `.` becomes `%XX` (uppercase hex), so `ABC` and `abc` differ.
    static func escapedIdentifier(_ id: String) throws -> String {
        var escaped = id.addingPercentEncoding(withAllowedCharacters: identifierCharacters) ?? ""
        if escaped.hasPrefix(".") { escaped = "%2E" + escaped.dropFirst() }
        guard !escaped.isEmpty, escaped.utf8.count <= maxComponentBytes else { throw LayoutError.invalidIdentifier(id) }
        return escaped
    }

    private static let identifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
}
