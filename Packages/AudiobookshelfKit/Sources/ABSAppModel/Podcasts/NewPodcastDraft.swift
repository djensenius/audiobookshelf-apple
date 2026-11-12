import ABSAPI
import ABSCore
import Foundation
import Observation

/// What adding a podcast is blocked by; the form disables Submit and says why.
public enum NewPodcastIssue: Sendable, Hashable, CaseIterable {
    /// The title is blank, or nothing of it is left for a folder name once sanitized.
    case titleMissing
    /// No folder is chosen, or the library has none.
    case folderMissing
}

/// The New podcast form (legacy `NewPodcastForm.vue`), filled from the picked directory entry and the parsed feed;
/// the podcast's folder is the chosen library folder joined with the sanitized title (see ``path``).
@MainActor
@Observable
public final class NewPodcastDraft: Identifiable {
    public var title: String
    public var author: String
    /// HTML from the directory, or the feed's plain description.
    public var description: String
    public var genres: [String]
    /// The chosen library folder's ID.
    public var folderID: String?
    public var autoDownloadEpisodes = false

    public let libraryID: String
    /// The library's folders, in server order.
    public private(set) var folders: [LibraryFolder]
    /// Read-only, as in legacy.
    public let feedURL: String
    /// The cover the server downloads for the new podcast.
    public let imageURL: String?
    /// The parsed feed, for its episode count and list.
    public let feed: PodcastFeed

    public private(set) var isSubmitting = false
    /// Why the last submit failed; cleared by the next one.
    public private(set) var submitError: (any Error)?

    @ObservationIgnored private let service: any AddPodcastService
    @ObservationIgnored private let releaseDate: String?
    @ObservationIgnored private let itunesPageURL: String?
    @ObservationIgnored private let itunesID: String?
    @ObservationIgnored private let itunesArtistID: String?
    @ObservationIgnored private let language: String?
    @ObservationIgnored private let explicit: Bool
    @ObservationIgnored private let type: String?

    /// Fills the form as legacy does: the directory entry's values (`nil` for a pasted RSS URL) first, then the
    /// feed's, then the looked-up `feedURL`. The first folder is chosen.
    public init(
        service: any AddPodcastService, libraryID: String, folders: [LibraryFolder], feed: PodcastFeed,
        directory: PodcastDirectoryResult? = nil, feedURL: String
    ) {
        let metadata = feed.metadata
        self.service = service
        self.libraryID = libraryID
        self.folders = folders
        self.feed = feed
        title = Self.first(directory?.title, metadata.title) ?? ""
        author = Self.first(directory?.artistName, metadata.author) ?? ""
        description = Self.first(directory?.description, metadata.descriptionPlain) ?? ""
        // Legacy takes the directory's genres even when empty (`[]` is truthy in JavaScript).
        genres = directory?.genres ?? metadata.categories
        self.feedURL = Self.first(directory?.feedURL, metadata.feedURL, feedURL) ?? feedURL
        imageURL = Self.first(directory?.cover, metadata.image)
        releaseDate = Self.first(directory?.releaseDate)
        itunesPageURL = Self.first(directory?.pageURL)
        itunesID = Self.first(directory?.itunesID)
        itunesArtistID = Self.first(directory?.itunesArtistID)
        language = Self.first(metadata.language)
        explicit = directory?.explicit ?? metadata.isExplicit
        type = Self.first(metadata.type)
        folderID = folders.first?.id
    }

    /// Takes a refreshed library's folders, keeping the choice only while it still exists.
    public func update(folders: [LibraryFolder]) {
        self.folders = folders
        if folder == nil { folderID = nil }
    }

    /// The chosen folder, if it's one of the library's.
    public var folder: LibraryFolder? {
        folders.first { $0.id == folderID }
    }

    /// The podcast's folder on the server; `nil` until a folder is chosen and the title has a usable name.
    public var path: String? {
        guard let folder else { return nil }
        return Self.podcastPath(folder: folder.fullPath, title: title)
    }

    /// What blocks submitting, empty when the form can be submitted.
    public var issues: Set<NewPodcastIssue> {
        var issues: Set<NewPodcastIssue> = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Self.sanitizedFilename(title).isEmpty {
            issues.insert(.titleMissing)
        }
        if folder == nil { issues.insert(.folderMissing) }
        return issues
    }

    public var canSubmit: Bool { issues.isEmpty && !isSubmitting }

    /// The body ``submit()`` sends; `nil` while ``issues`` isn't empty.
    public var request: NewPodcastRequest? {
        guard issues.isEmpty, let folder, let path else { return nil }
        let metadata = NewPodcastRequest.Metadata(
            title: title, author: Self.first(author), description: Self.first(description), releaseDate: releaseDate,
            // The server drops all genres if any is empty.
            genres: genres.filter { !$0.isEmpty }, feedURL: feedURL, imageURL: imageURL,
            itunesPageURL: itunesPageURL, itunesID: itunesID, itunesArtistID: itunesArtistID, language: language,
            explicit: explicit, type: type)
        return NewPodcastRequest(
            libraryID: libraryID, folderID: folder.id, path: path,
            media: .init(metadata: metadata, autoDownloadEpisodes: autoDownloadEpisodes))
    }

    /// Creates the podcast and returns its item's ID; `nil` without a request while ``canSubmit`` is false, or with
    /// ``submitError`` set when the server refuses.
    @discardableResult
    public func submit() async -> String? {
        guard !isSubmitting, let request else { return nil }
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }
        do {
            return try await service.createPodcast(request).id
        } catch {
            if !(error is CancellationError) { submitError = error }
            return nil
        }
    }

    /// The server's own message for a 400 (such as "Podcast already exists"), which legacy shows; `nil` for other
    /// failures, such as 403's unlocalized "Forbidden", which show `ToastPodcastCreateFailed`.
    public var submitErrorMessage: String? {
        guard case .http(400, let message?) = submitError as? APIError else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Paths

    /// Legacy `Path.join(folder, $sanitizeFilename(title))`: the folder without trailing slashes, a slash, and the
    /// sanitized title; `nil` when nothing of the title is left.
    public nonisolated static func podcastPath(folder: String, title: String) -> String? {
        let name = sanitizedFilename(title)
        guard !name.isEmpty else { return nil }
        var folder = folder
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        return folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// The longest file name legacy keeps, in UTF-16 code units.
    nonisolated static let maxFilenameLength = 240
    /// The longest directory name common server filesystems accept, in UTF-8 bytes.
    nonisolated static let maxFilenameBytes = 255

    /// A port of legacy `$sanitizeFilename` (`plugins/init.client.js`): the first `:` becomes ` - `; `/ ? < > \ : * |
    /// "`, control characters and line breaks are removed; a name of only dots or a reserved Windows device name
    /// becomes empty; trailing dots and spaces are removed; and a name over 240 UTF-16 code units (or, unlike legacy,
    /// 255 UTF-8 bytes) is shortened by whole characters before its extension.
    public nonisolated static func sanitizedFilename(_ input: String) -> String {
        var name = input
        if let colon = name.firstIndex(of: ":") { name.replaceSubrange(colon...colon, with: " - ") }
        let illegal: Set<Character> = ["/", "?", "<", ">", "\\", ":", "*", "|", "\""]
        name = String(
            String.UnicodeScalarView(
                name.unicodeScalars.filter { scalar in
                    let value = scalar.value
                    if value <= 0x1F || (0x80...0x9F).contains(value) { return false }
                    return !illegal.contains(Character(scalar))
                }))
        if name.allSatisfy({ $0 == "." }) { name = "" }
        if name.wholeMatch(of: /(?i)(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?/) != nil { name = "" }
        while let last = name.last, last == "." || last == " " { name.removeLast() }
        let fits = { (name: String) in name.utf16.count <= maxFilenameLength && name.utf8.count <= maxFilenameBytes }
        if !fits(name) {
            let (base, ext) = splitExtension(name)
            var shortened = base
            while !shortened.isEmpty, !fits(shortened + ext) { shortened.removeLast() }
            if fits(shortened + ext) {
                name = shortened + ext
            } else {
                while !fits(name) { name.removeLast() }
            }
        }
        return name
    }

    /// Node's `path.extname` split: the extension starts at the last dot, unless that dot starts the name.
    private nonisolated static func splitExtension(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// The first value that isn't `nil` or blank.
    private nonisolated static func first(_ values: String?...) -> String? {
        values.lazy.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
