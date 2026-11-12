import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import Audiobookshelf

/// The fixture server's replies decode through the production endpoints, so a model change that
/// breaks a fixture fails here rather than in a UI test (docs/testing/ui-tests.md).
@MainActor
struct FixtureServerTests {
    private let client: APIClient

    init() throws {
        client = APIClient(
            configuration: try APIClientConfiguration(baseURL: URL(string: FixtureServer.address)!),
            tokenProvider: FixedTokens(), sessionConfiguration: FixtureServer.sessionConfiguration())
    }

    @Test func validatesAndSignsIn() async throws {
        let validator = ServerValidator(sessionConfiguration: FixtureServer.sessionConfiguration)
        let server = try await validator.validate(address: FixtureServer.address)
        let login = try await validator.login(to: server, username: "fixture", password: "fixture")
        #expect(login.response.user.username == "fixture")
        #expect(login.response.userDefaultLibraryId == SampleLibrary.libraryID)
        let authorized = try await validator.authorize(with: client)
        #expect(authorized.response.user.id == login.response.user.id)
        #expect(try await client.send(AuthEndpoints.ping()).success)
        _ = try await client.send(UserEndpoints.me())
    }

    @Test func servesTheSampleLibrary() async throws {
        let libraries = try await client.send(LibraryEndpoints.libraries()).libraries
        #expect(libraries.map(\.id) == [SampleLibrary.libraryID])
        let library = try await client.send(LibraryEndpoints.library(id: SampleLibrary.libraryID))
        #expect(library.filterData.authors.count == 5)

        let shelves = try await client.send(LibraryEndpoints.personalized(libraryID: SampleLibrary.libraryID))
        #expect(
            shelves.elements.map(\.id) == ["continue-listening", "recently-added", "recent-series", "newest-authors"])
        #expect(shelves.elements.allSatisfy { $0.total ?? 0 > 0 })

        let items = try await client.send(LibraryEndpoints.items(libraryID: SampleLibrary.libraryID))
        #expect(items.results.map(\.id) == SampleLibrary.books.map(\.id))
        #expect(items.results.map(\.book?.metadata.title) == SampleLibrary.books.map(\.book?.metadata.title))
        #expect(items.rawCount == items.results.count)
    }

    @Test func servesAnItemAndItsCover() async throws {
        let item = try await client.send(ItemEndpoints.item(id: SampleLibrary.prideAndPrejudice.id))
        #expect(item.book?.metadata.title == "Pride and Prejudice")
        #expect(item.book?.metadata.authors?.map(\.name) == ["Jane Austen"])

        let session = URLSession(configuration: FixtureServer.sessionConfiguration())
        let url = URL(string: "\(FixtureServer.address)/api/items/li_pride/cover?width=400")!
        let (data, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func answersAMissingFixtureWithNotFound() async throws {
        await #expect(throws: APIError.notFound) {
            try await client.send(ItemEndpoints.item(id: "li_emma"))
        }
        #expect(FixtureServer.reply(method: "GET", path: "/api/unknown") == .notFound)
        #expect(FixtureServer.reply(method: "DELETE", path: "/api/me") == .notFound)
    }

    @Test func leavesOtherHostsAlone() {
        let other = URLRequest(url: URL(string: "https://abs.example.com/status")!)
        #expect(!FixtureURLProtocol.canInit(with: other))
        #expect(
            URLSessionConfiguration.absConnection().protocolClasses?.contains { $0 == FixtureURLProtocol.self } != true)
    }
}

/// The fixture server accepts any token.
private struct FixedTokens: TokenProvider {
    func tokens() async -> AuthTokens? { AuthTokens(accessToken: "fixture-access-token", refreshToken: "r") }
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool { false }
}
