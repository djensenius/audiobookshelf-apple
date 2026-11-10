import ABSCore

/// The kind of library a scene shows, which decides its sections (``AppTab/sections(for:)``).
///
/// Navigation keeps its own two-case type so ``Router`` and its snapshot depend only on
/// Foundation and Observation.
public enum LibraryKind: String, Hashable, Codable, Sendable {
    case book, podcast

    /// The kind for a server media type, or `nil` for a type this client doesn't know.
    public init?(_ mediaType: MediaType) {
        switch mediaType {
        case .book: self = .book
        case .podcast: self = .podcast
        case .unknown: return nil
        }
    }
}
