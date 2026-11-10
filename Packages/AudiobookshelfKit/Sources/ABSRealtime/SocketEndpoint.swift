import Foundation

/// Builds the Socket.IO WebSocket endpoint for a server address.
public enum SocketEndpoint {
    /// `https://host/abs` → `wss://host/abs/socket.io/?EIO=4&transport=websocket`. Keeps the
    /// port and any subpath (the server also listens on `<RouterBasePath>/socket.io`). Returns
    /// `nil` for schemes other than http, https, ws and wss, or an address without a host.
    public static func url(forServerAddress address: URL) -> URL? {
        guard var components = URLComponents(url: address, resolvingAgainstBaseURL: false),
            let host = components.host, !host.isEmpty
        else { return nil }
        switch components.scheme?.lowercased() {
        case "http", "ws": components.scheme = "ws"
        case "https", "wss": components.scheme = "wss"
        default: return nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/socket.io/"
        components.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket"),
        ]
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    /// Custom headers for the upgrade request, without `Authorization` or `Cookie`: the socket
    /// authenticates with the `auth` event, and those headers are never user-configurable.
    public static func filteredHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { name, _ in
            let lowercased = name.lowercased()
            return lowercased != "authorization" && lowercased != "cookie"
        }
    }
}
