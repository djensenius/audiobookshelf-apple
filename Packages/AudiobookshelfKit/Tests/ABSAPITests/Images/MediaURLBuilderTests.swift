import ABSCore
import Foundation
import Testing

@testable import ABSAPI

private func makeBuilder(customHeaders: [String: String] = [:]) throws -> MediaURLBuilder {
    let base = try #require(URL(string: "https://abs.example/abs"))
    return MediaURLBuilder(configuration: try APIClientConfiguration(baseURL: base, customHeaders: customHeaders))
}

@Suite struct MediaURLBuilderTests {
    @Test(arguments: [
        (1.0, ImageWidthBucket.small), (300, .small), (300.5, .medium), (600, .medium), (601, .large),
        (1200, .large), (4000, .large),
    ])
    func bucketIsSmallestAtLeastPixelWidth(pixelWidth: Double, expected: ImageWidthBucket) {
        #expect(ImageWidthBucket(pixelWidth: pixelWidth) == expected)
    }

    @Test(arguments: ImageWidthBucket.allCases)
    func coverURLUsesBucketAndWebp(width: ImageWidthBucket) throws {
        let url = try #require(try makeBuilder().coverURL(itemID: "li1", updatedAt: 1_700_000_000_123, width: width))
        #expect(
            url.absoluteString
                == "https://abs.example/abs/api/items/li1/cover?width=\(width.rawValue)&format=webp&ts=1700000000123")
    }

    @Test func coverURLWithoutUpdatedAtOmitsTs() throws {
        let url = try #require(try makeBuilder().coverURL(itemID: "li1", updatedAt: nil, width: .large, format: .jpeg))
        #expect(url.absoluteString == "https://abs.example/abs/api/items/li1/cover?width=1200&format=jpeg")
    }

    @Test func authorImageURL() throws {
        let url = try #require(try makeBuilder().authorImageURL(authorID: "aut1", updatedAt: 5, width: .small))
        #expect(url.absoluteString == "https://abs.example/abs/api/authors/aut1/image?width=300&format=webp&ts=5")
    }

    @Test func ebookURLs() throws {
        let builder = try makeBuilder()
        #expect(builder.ebookURL(itemID: "li1")?.absoluteString == "https://abs.example/abs/api/items/li1/ebook")
        #expect(
            builder.ebookURL(itemID: "li1", fileID: "12345")?.absoluteString
                == "https://abs.example/abs/api/items/li1/ebook/12345")
    }

    @Test func idsAreEncodedAsOnePathSegment() throws {
        let builder = try makeBuilder()
        #expect(
            builder.coverURL(itemID: "a/b?c", updatedAt: nil, width: .small)?.absoluteString
                == "https://abs.example/abs/api/items/a%2Fb%3Fc/cover?width=300&format=webp")
        #expect(
            builder.authorImageURL(authorID: "..", updatedAt: nil, width: .small)?.absoluteString
                == "https://abs.example/abs/api/authors/%2E%2E/image?width=300&format=webp")
        #expect(
            builder.ebookURL(itemID: "a#b", fileID: "%")?.absoluteString
                == "https://abs.example/abs/api/items/a%23b/ebook/%25")
    }

    @Test(arguments: [ImageKind.itemCover, .authorImage])
    func serverImageRequestSendsCustomHeadersButNoToken(kind: ImageKind) throws {
        let builder = try makeBuilder(customHeaders: ["CF-Access-Client-Id": "proxy-id"])
        let request = try #require(
            builder.imageRequest(for: .server(kind: kind, entityID: "id1", updatedAt: 9, width: .medium)))

        let components = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(components.queryItems?.map(\.name) == ["width", "format", "ts"])
        #expect(components.queryItems?.first { $0.name == "format" }?.value == "webp")
        #expect(components.queryItems?.first { $0.name == "width" }?.value == "600")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "proxy-id")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.url?.absoluteString.contains("token") == false)
    }

    @Test func externalImageRequestSendsNoCustomHeaders() throws {
        let builder = try makeBuilder(customHeaders: ["CF-Access-Client-Id": "proxy-id"])
        let external = try #require(URL(string: "https://images.example/cover.jpg"))

        let request = try #require(builder.imageRequest(for: .external(external)))

        #expect(request.url == external)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test func nonHTTPExternalSourceIsRejected() throws {
        let file = try #require(URL(string: "file:///tmp/cover.jpg"))
        #expect(try makeBuilder().imageRequest(for: .external(file)) == nil)
    }

    @Test(arguments: ["http://127.0.0.1:8080/admin/reboot", "http://192.168.1.1/cover.jpg", "http://nas.local/c.jpg"])
    func externalSourceOnThisDeviceOrTheLocalNetworkIsRejected(url: String) throws {
        let external = try #require(URL(string: url))
        #expect(try makeBuilder().imageRequest(for: .external(external)) == nil)
    }

    @Test func externalSourceOnALocalNetworkServersOwnOriginIsAllowed() throws {
        let base = try #require(URL(string: "http://192.168.1.5:13378"))
        let builder = MediaURLBuilder(configuration: try APIClientConfiguration(baseURL: base))
        let external = try #require(URL(string: "http://192.168.1.5:13378/metadata/items/li1/cover.jpg"))

        #expect(builder.imageRequest(for: .external(external))?.url == external)
    }
}
