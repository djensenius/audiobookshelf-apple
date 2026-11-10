import Foundation

extension ServerValidator {
    /// Sends `endpoint`, which doesn't follow redirects, through `client`, and sends it once
    /// more if the reply is a proxy's cookie redirect.
    ///
    /// A reverse proxy, load balancer or auth gateway may set a cookie on first contact and
    /// redirect back to the same URL, for example when `/api/authorize` is the first request of
    /// a new account client whose jar doesn't hold that cookie yet. A redirect whose `Location`
    /// is exactly the request URL and that sets cookies has them stored in `client`'s jar, and
    /// the same request (method, body and headers) is sent again to the same URL. The redirect
    /// itself is never followed, so no hop can change the method or leave the origin. Any other
    /// redirect, one that sets no cookies, or a second one is returned as is. An endpoint that
    /// doesn't send cookies is never retried.
    static func sendRetryingCookieRedirect(
        _ endpoint: Endpoint<Data>, client: APIClient
    ) async throws -> APIResponse<Data> {
        let reply = try await client.response(for: endpoint)
        guard endpoint.sendsCookies, storeSameURLRedirectCookies(of: reply.httpResponse, in: client.cookieStorage)
        else { return reply }
        return try await client.response(for: endpoint)
    }

    /// Stores the cookies `response` sets in `jar` if it is a redirect back to its own URL.
    /// Returns whether it stored any.
    private static func storeSameURLRedirectCookies(of response: HTTPURLResponse, in jar: HTTPCookieStorage?) -> Bool {
        guard [301, 302, 303, 307, 308].contains(response.statusCode), let url = response.url,
            let location = response.value(forHTTPHeaderField: "Location"),
            URL(string: location, relativeTo: url)?.absoluteString == url.absoluteString
        else { return false }
        return WrittenCookies.store(from: response, in: jar)
    }
}
