import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import Audiobookshelf

/// The fixture server's replies decode through the production endpoints, so a model change that
/// breaks a fixture fails here rather than in a UI test (docs/testing/ui-tests.md).
/// Serialized: ``FixtureServer/environment()`` empties the fixture cover cache another test loads into.
@MainActor @Suite(.serialized)
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

    /// Connect's first `/status` check, and the add-server flow's, go through the fixture
    /// launch's injected session rather than the real network.
    @Test(arguments: [false, true])
    func connectFlowValidatesThroughTheFixtureSession(addingServer: Bool) async throws {
        let environment = FixtureServer.environment()
        let accounts = try #require(environment.accounts)
        let model = ConnectFlowView.model(
            accounts: accounts, lifecycle: addingServer ? environment.lifecycle : nil,
            localNetwork: PreviewLocalNetworkAccess())
        #expect(model.phase == .address)
        model.address = FixtureServer.address
        await model.submitAddress()
        #expect(model.failure == nil)
        #expect(model.phase == .login)
    }

    /// Fixture covers load without the network monitor and cache only in the fixture directory.
    @Test func loadsCoversIntoTheirOwnCacheWithoutTheNetworkMonitor() async throws {
        let source = FixtureServer.coverSource()
        #expect(source.directory == FixtureServer.coverDirectory)
        #expect(source.isOnline?() == true)
        let services = ImageServices(accounts: nil, covers: source)
        let key = try await coverKey(in: services)
        _ = try await services.pipeline.image(for: key, pixelBox: PixelBox(width: 8, height: 8))
        #expect(!files(in: FixtureServer.coverDirectory).isEmpty)
        #expect(files(in: CoverFileStore.defaultDirectory()).allSatisfy { !$0.path.contains(key.serverID.uuidString) })
    }

    /// The cover source's gate, not the network monitor, decides whether a cover may load.
    @Test func coverLoadsFollowTheSourcesOnlineGate() async throws {
        let directory = URL.temporaryDirectory.appending(path: "FixtureServerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let services = ImageServices(
            accounts: nil,
            covers: CoverSource(
                sessionConfiguration: FixtureServer.fixtureConfiguration(.ephemeral), directory: directory,
                isOnline: { false }))
        let key = try await coverKey(in: services)
        await #expect(throws: ImagePipelineError.offline) {
            _ = try await services.pipeline.image(for: key, pixelBox: PixelBox(width: 8, height: 8))
        }
    }

    /// A fixture cover's key, with the fixture server's request builder set for a new server.
    private func coverKey(in services: ImageServices) async throws -> ImageKey {
        let server = UUID()
        let configuration = try APIClientConfiguration(baseURL: URL(string: FixtureServer.address)!)
        await services.pipeline.setRequestBuilder(MediaURLBuilder(configuration: configuration), for: server)
        return ImageKey(serverID: server, kind: .itemCover, entityID: "li_pride", updatedAt: 10)
    }

    private func files(in directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }
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
