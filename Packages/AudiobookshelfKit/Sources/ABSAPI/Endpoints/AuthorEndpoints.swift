import Foundation

/// Read endpoints for an author's landing page.
public enum AuthorEndpoints {
    /// `GET /api/authors/:id?include=items,series`.
    public static func author(id: String) -> Endpoint<AuthorDetailResponse> {
        Endpoint(
            .get, "/api/authors/\(pathSegment(id))",
            query: [URLQueryItem(name: "include", value: "items,series")])
    }
}
