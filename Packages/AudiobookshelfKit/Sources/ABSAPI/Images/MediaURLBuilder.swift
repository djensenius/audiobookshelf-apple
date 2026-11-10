import ABSCore
import Foundation

/// Builds cover, author image, and ebook URLs for one server connection (ADR 0005).
///
/// Image requests never carry the Audiobookshelf access token (no `Authorization` header and
/// no `?token=`): both image routes are unauthenticated on every supported server. They carry
/// the connection's custom headers to the server only, and never cookies.
///
/// The builder is a value snapshot of one connection's address and custom headers. When either
/// changes, `AppEnvironment` must build a new one and hand it to the image pipeline (the same
/// moment it calls ``APIClient/setCustomHeaders(_:)``).
public struct MediaURLBuilder: ImageRequestBuilding {
    private let configuration: APIClientConfiguration

    public init(configuration: APIClientConfiguration) {
        self.configuration = configuration
    }

    /// `GET /api/items/:id/cover?width=&format=&ts=`.
    public func coverURL(
        itemID: String, updatedAt: Int?, width: ImageWidthBucket, format: ImageFormat = .webp
    ) -> URL? {
        imageURL(path: "/api/items/\(pathSegment(itemID))/cover", updatedAt: updatedAt, width: width, format: format)
    }

    /// `GET /api/authors/:id/image?width=&format=&ts=`.
    public func authorImageURL(
        authorID: String, updatedAt: Int?, width: ImageWidthBucket, format: ImageFormat = .webp
    ) -> URL? {
        imageURL(
            path: "/api/authors/\(pathSegment(authorID))/image", updatedAt: updatedAt, width: width, format: format)
    }

    /// `GET /api/items/:id/ebook[/:fileID]`: the item's primary ebook, or the ebook file with
    /// inode `fileID`. The route requires the access token: read it with
    /// ``ItemEndpoints/ebook(itemID:fileID:)`` through ``APIClient``, or have the downloader
    /// add the `Authorization` header and the connection's custom headers. Never use `?token=`.
    public func ebookURL(itemID: String, fileID: String? = nil) -> URL? {
        let path = ItemEndpoints.ebookPath(itemID: itemID, fileID: fileID)
        return try? APIClient.url(base: configuration.baseURL, path: path, query: [])
    }

    public func imageRequest(for source: ImageSource) -> URLRequest? {
        let url: URL
        let sendsCustomHeaders: Bool
        switch source {
        case .server(let kind, let entityID, let updatedAt, let width, let format):
            let built =
                switch kind {
                case .itemCover: coverURL(itemID: entityID, updatedAt: updatedAt, width: width, format: format)
                case .authorImage:
                    authorImageURL(authorID: entityID, updatedAt: updatedAt, width: width, format: format)
                }
            guard let built else { return nil }
            url = built
            sendsCustomHeaders = true
        case .external(let external):
            guard let scheme = external.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return nil
            }
            url = external
            // Credentials never leave the server's origin.
            sendsCustomHeaders = false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.timeout
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        if sendsCustomHeaders {
            for (name, value) in configuration.customHeaders {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        return request
    }

    private func imageURL(path: String, updatedAt: Int?, width: ImageWidthBucket, format: ImageFormat) -> URL? {
        var query = [
            URLQueryItem(name: "width", value: String(width.rawValue)),
            URLQueryItem(name: "format", value: format.rawValue),
        ]
        if let updatedAt { query.append(URLQueryItem(name: "ts", value: String(updatedAt))) }
        return try? APIClient.url(base: configuration.baseURL, path: path, query: query)
    }
}
