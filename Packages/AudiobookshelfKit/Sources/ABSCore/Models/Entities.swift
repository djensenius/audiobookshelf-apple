import Foundation

/// An author. Inside book metadata only `id` and `name` are present; author lists add the rest.
public struct Author: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let asin: String?
    public let description: String?
    public let imagePath: String?
    public let libraryId: String?
    /// Epoch milliseconds.
    public let addedAt: Int?
    /// Epoch milliseconds.
    public let updatedAt: Int?
    public let numBooks: Int?
}

/// A series. Inside book metadata it carries the book's `sequence`; series lists and shelves
/// carry `books`.
public struct Series: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let nameIgnorePrefix: String?
    public let description: String?
    public let sequence: String?
    public let libraryId: String?
    /// Epoch milliseconds.
    public let addedAt: Int?
    /// Epoch milliseconds.
    public let updatedAt: Int?
    public let books: [LibraryItem]?
    /// Seconds.
    public let totalDuration: Double?
}
