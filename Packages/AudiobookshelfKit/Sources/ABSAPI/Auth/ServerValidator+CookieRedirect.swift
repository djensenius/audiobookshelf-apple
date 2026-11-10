import Foundation

extension ServerValidator {
    /// Sends `endpoint`, which doesn't follow redirects, through `client`, and sends it once
    /// more if the reply is a proxy's cookie redirect.
    ///
    /// A reverse proxy, load balancer or auth gateway may set a cookie on first contact and
    /// redirect back to the same URL, for example when `/api/authorize` is the first request of
    /// a new account client whose jar doesn't hold that cookie yet. When a 301, 302, 307 or 308
    /// has a `Location` that is exactly the request URL, its cookies (except the endpoint's
    /// withheld ones) are stored in `client`'s jar. If that gives the request a cookie it didn't
    /// send, the same request (method, body and headers) is sent again to the same URL. The
    /// redirect itself is never followed, so no hop can change the method or leave the origin.
    ///
    /// Everything else is returned as is: a redirect to any other URL; one whose cookies won't be
    /// sent to this URL or were sent already (another path or domain, a deletion, an unchanged
    /// value); a second redirect; and any reply to an endpoint that doesn't send cookies. A 303
    /// (See Other) is never retried: it says the request was handled, so posting it again could,
    /// for example, create a second session.
    static func sendRetryingCookieRedirect(
        _ endpoint: Endpoint<Data>, client: APIClient
    ) async throws -> APIResponse<Data> {
        guard endpoint.sendsCookies, let jar = client.cookieStorage else {
            return try await client.response(for: endpoint)
        }
        let url = try APIClient.url(
            base: await client.configuration.baseURL, path: endpoint.path, query: endpoint.query)
        let withheld = endpoint.withheldCookies
        let sent = cookiePairs(jar.cookies(for: url) ?? [], withholding: withheld)
        let reply = try await client.response(for: endpoint)
        guard isSameURLRedirect(reply.httpResponse, to: url) else { return reply }
        let stored = WrittenCookies.store(from: reply.httpResponse, in: jar, withholding: withheld)
        let sendable = cookiePairs(jar.cookies(for: url) ?? [], withholding: withheld)
        guard !cookiePairs(stored, withholding: withheld).intersection(sendable).subtracting(sent).isEmpty
        else { return reply }
        return try await client.response(for: endpoint)
    }

    /// Whether `response` is a 301, 302, 307 or 308 whose `Location` resolves to exactly `url`.
    private static func isSameURLRedirect(_ response: HTTPURLResponse, to url: URL) -> Bool {
        guard [301, 302, 307, 308].contains(response.statusCode),
            let location = response.value(forHTTPHeaderField: "Location")
        else { return false }
        return URL(string: location, relativeTo: url)?.absoluteString == url.absoluteString
    }

    /// The `name=value` pairs of `cookies`, except the `withheld` names.
    private static func cookiePairs(_ cookies: [HTTPCookie], withholding withheld: Set<String>) -> Set<String> {
        Set(cookies.filter { !withheld.contains($0.name) }.map { "\($0.name)=\($0.value)" })
    }
}
