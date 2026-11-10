import Foundation
import Testing

@testable import ABSCore

@Suite struct RedirectPolicyTests {
    @Test(arguments: [
        ("https://a.example", "https://a.example:443/x", true),
        ("https://a.example", "https://A.EXAMPLE/x", true),
        ("http://a.example", "https://a.example/x", true),
        ("http://a.example:8080", "https://a.example:8443/x", false),
        ("https://a.example", "http://a.example/x", false),
        ("https://a.example", "https://b.example/x", false),
        ("https://a.example", "https://a.example:8443/x", false),
    ])
    func comparesOrigins(current: String, next: String, expected: Bool) throws {
        let current = try #require(URL(string: current))
        let next = try #require(URL(string: next))
        #expect(RedirectPolicy.isSameOrigin(current, next) == expected)
    }

    @Test func stripsOnceTheChainLeavesTheOrigin() throws {
        let origin = try #require(URL(string: "https://a.example/api"))
        var original = URLRequest(url: origin)
        original.setValue("secret", forHTTPHeaderField: "CF-Access-Client-Secret")
        let response = try #require(HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil))

        let same = RedirectPolicy.hop(
            following: response, to: URLRequest(url: try #require(URL(string: "https://a.example/b"))),
            original: original, wasStripped: false)
        #expect(same?.isStripped == false)
        #expect(same?.request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")

        let cross = RedirectPolicy.hop(
            following: response, to: URLRequest(url: try #require(URL(string: "https://b.example/b"))),
            original: original, wasStripped: false)
        #expect(cross?.isStripped == true)
        #expect(cross?.request.allHTTPHeaderFields?.isEmpty ?? true)
        #expect(cross?.request.httpShouldHandleCookies == false)

        let back = RedirectPolicy.hop(
            following: response, to: URLRequest(url: origin), original: original, wasStripped: true)
        #expect(back?.isStripped == true)
    }

    /// A hop whose proposed method differs (a POST turned into a GET by a 301, 302 or 303) is
    /// refused, on the origin or off it; a 307 or 308 keeps the method and is followed.
    @Test func refusesHopsThatChangeTheMethod() throws {
        let origin = try #require(URL(string: "https://a.example/logout"))
        var original = URLRequest(url: origin)
        original.httpMethod = "POST"
        let response = try #require(HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil))
        for target in ["https://a.example/v2/logout", "https://b.example/logout"] {
            var asGet = URLRequest(url: try #require(URL(string: target)))
            asGet.httpMethod = "GET"
            #expect(RedirectPolicy.hop(following: response, to: asGet, original: original, wasStripped: false) == nil)
            var asPost = asGet
            asPost.httpMethod = "POST"
            #expect(RedirectPolicy.hop(following: response, to: asPost, original: original, wasStripped: false) != nil)
        }
        let get = URLRequest(url: origin)
        let next = URLRequest(url: try #require(URL(string: "https://a.example/b")))
        #expect(RedirectPolicy.hop(following: response, to: next, original: get, wasStripped: false) != nil)
    }
}
