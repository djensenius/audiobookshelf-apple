import Foundation

/// A tab of the root `TabView` (ADR 0004). Each tab has its own navigation path.
///
/// Home, Library, Search, Downloads and Account exist for every library. The rest are
/// sidebar-only library sections, which replace the legacy `BookshelfNavBar.vue`; in compact
/// width they are reached from the Library root's section picker (``Router/librarySection``).
public enum AppTab: String, Hashable, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case home, library, search, downloads, account
    case series, collections, authors, playlists, latest, addPodcast

    /// The sidebar-only library sections, in sidebar order.
    public static let sections: [AppTab] = [.series, .collections, .authors, .playlists, .latest, .addPodcast]

    /// Whether this is a sidebar-only library section, hidden from the compact tab bar.
    public var isSection: Bool { Self.sections.contains(self) }

    /// Whether this tab's path belongs to the current library, so a library switch resets it.
    /// Downloads and Account are kept.
    public var isLibraryScoped: Bool {
        switch self {
        case .downloads, .account: false
        default: true
        }
    }

    /// Every section a library of `kind` can have, before permissions and content are
    /// considered. Book libraries have Series, Collections, Authors and Playlists; podcast
    /// libraries have Latest, Add podcast (admins only) and Playlists. A library of unknown
    /// kind has none.
    public static func sections(for kind: LibraryKind?) -> Set<AppTab> {
        switch kind {
        case .book: [.series, .collections, .authors, .playlists]
        case .podcast: [.latest, .addPodcast, .playlists]
        case nil: []
        }
    }

    /// The sections a library shows, following the legacy `BookshelfNavBar.vue`: Add podcast
    /// only for users who can add podcasts, and Playlists only when the user has playlists.
    public static func sections(for kind: LibraryKind?, canAddPodcast: Bool, hasPlaylists: Bool) -> Set<AppTab> {
        var sections = sections(for: kind)
        if !canAddPodcast { sections.remove(.addPodcast) }
        if !hasPlaylists { sections.remove(.playlists) }
        return sections
    }
}
