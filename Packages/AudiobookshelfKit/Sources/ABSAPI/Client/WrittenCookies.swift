import Foundation

/// The `Cookie` rule for a request whose cookies ``APIClient`` writes itself instead of
/// `URLSession` (an endpoint with ``Endpoint/withheldCookies``, such as `POST /logout`).
///
/// Such a request has `httpShouldHandleCookies` off, so `URLSession` neither stores a redirect's
/// `Set-Cookie` nor adds the jar's cookies to the next hop: the original header would be re-sent
/// as is, without a cookie a proxy set on its redirect. ``RedirectChainDelegate`` uses this on
/// each followed same-origin hop instead (hops off the origin are stripped of cookies or refused).
struct WrittenCookies: Sendable {
    /// The connection's cookie jar.
    let jar: HTTPCookieStorage?
    /// Cookies never sent from the jar, or stored from a redirect.
    let withheld: Set<String>
    /// The endpoint's own `Cookie` header, sent after the jar's and replacing same-named ones.
    let explicit: String?

    /// The `Cookie` header for a request to `url`, or `nil` if there are no cookies.
    func header(for url: URL) -> String? {
        APIClient.cookieHeader(jar: jar?.cookies(for: url) ?? [], withholding: withheld, explicit: explicit)
    }

    /// Stores the cookies a followed redirect `response` sets, as `URLSession` does for requests
    /// whose cookies it handles, except the withheld names, which this request keeps out of the jar.
    func store(from response: HTTPURLResponse) {
        Self.store(from: response, in: jar, withholding: withheld)
    }

    /// Stores the cookies `response` sets in `jar`, except the `withheld` names. Returns the
    /// cookies it passed to the jar, which may reject them (or, for an expired one, delete the
    /// stored cookie).
    @discardableResult
    static func store(
        from response: HTTPURLResponse, in jar: HTTPCookieStorage?, withholding withheld: Set<String> = []
    ) -> [HTTPCookie] {
        guard let jar, let url = response.url else { return [] }
        var fields: [String: String] = [:]
        for case let (name as String, value as String) in response.allHeaderFields {
            fields[name] = value
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .filter { !withheld.contains($0.name) }
        jar.setCookies(cookies, for: url, mainDocumentURL: nil)
        return cookies
    }
}
