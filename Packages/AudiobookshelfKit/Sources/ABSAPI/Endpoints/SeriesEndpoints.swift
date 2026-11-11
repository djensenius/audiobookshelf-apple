import Foundation

/// Read endpoints for a series' landing page.
public enum SeriesEndpoints {
    /// `GET /api/series/:id`, optionally including the current user's aggregate progress.
    ///
    /// This metadata route is deprecated upstream but supported on both verified servers.
    /// It does not include books; unknown series and series with no accessible books return 404.
    public static func detail(id: String, includeProgress: Bool = true) -> Endpoint<SeriesDetailResponse> {
        Endpoint(
            .get, "/api/series/\(pathSegment(id))",
            query: includeProgress ? [URLQueryItem(name: "include", value: "progress")] : [])
    }
}
