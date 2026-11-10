import ABSCore

/// Library-wide collection writes. Update permission is required except for delete, which requires
/// delete permission. Collections have no owner and survive deletion of the creating user.
public enum CollectionEndpoints {
    /// `POST /api/collections`: returns the flat expanded collection.
    public static func create(_ request: CollectionCreateRequest) -> Endpoint<LibraryCollection> {
        Endpoint(.post, "/api/collections", body: request)
    }

    /// `PATCH /api/collections/:id`: metadata and reorder only, including successful no-ops.
    public static func update(id: String, _ request: CollectionUpdateRequest) -> Endpoint<LibraryCollection> {
        Endpoint(.patch, path(id), body: request)
    }

    /// `DELETE /api/collections/:id`: 200 plain `OK`, not a JSON collection.
    public static func delete(id: String) -> Endpoint<EmptyResponse> {
        Endpoint(.delete, path(id))
    }

    /// Adds valid books, ignoring existing members and invalid IDs; zero valid IDs returns 400.
    /// Newly appended books follow database order, not necessarily request order.
    public static func addBooks(id: String, _ request: CollectionBooksRequest) -> Endpoint<LibraryCollection> {
        Endpoint(.post, "\(path(id))/batch/add", body: request)
    }

    /// Removes members; unknown/nonmember IDs are no-ops. An empty array returns the server's 500 quirk.
    public static func removeBooks(id: String, _ request: CollectionBooksRequest) -> Endpoint<LibraryCollection> {
        Endpoint(.post, "\(path(id))/batch/remove", body: request)
    }

    private static func path(_ id: String) -> String {
        "/api/collections/\(pathSegment(id))"
    }
}
