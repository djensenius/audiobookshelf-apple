import ABSAPI
import ABSCore
import Foundation
import Testing

/// Collection-local ownership: collections are library-wide, not children of the creating user.
/// Register exact IDs before decoding expanded books; always delete collections before users.
actor CollectionContractFixture {
    let admin: ContractSession
    let seed: SeedData
    private var collectionIDs: [String] = []
    private var userIDs: [String] = []

    init(admin: ContractSession, seed: SeedData) {
        self.admin = admin
        self.seed = seed
    }

    static func withFixture<T: Sendable>(
        _ body: (CollectionContractFixture) async throws -> T
    ) async throws -> T {
        let fixture = try await CollectionContractFixture(
            admin: ContractAdmin.shared.session(), seed: ContractSeed.shared.data())
        let value: T
        do {
            value = try await body(fixture)
        } catch {
            let failures = await fixture.cleanup()
            for failure in failures { Issue.record("Collection cleanup failed: \(failure)") }
            throw error
        }
        let failures = await fixture.cleanup()
        if !failures.isEmpty { throw CleanupFailure(resources: failures) }
        return value
    }

    func user(elevated: Bool = true, accessibleLibraries: [String]? = nil) async throws -> ContractSession {
        let name = "collection-" + UUID().uuidString
        let password = UUID().uuidString
        var permissions: [String: Bool]? = elevated ? ["update": true, "delete": true] : nil
        if accessibleLibraries != nil {
            permissions = (permissions ?? [:]).merging(["accessAllLibraries": false]) { _, new in new }
        }
        let created = try await admin.client.send(
            Endpoint<CreatedUser>(
                .post, "/api/users",
                body: NewUser(
                    username: name, password: password, permissions: permissions,
                    librariesAccessible: accessibleLibraries)))
        userIDs.append(created.user.id)
        let session = try await ContractServer.require().signIn(username: name, password: password)
        #expect(session.user.type == .user)
        #expect(session.user.permissions.update == elevated)
        #expect(session.user.permissions.delete == elevated)
        return session
    }

    /// One actual request, not a replay to capture JSON. APIClient still validates HTTP failures.
    /// Comparing raw and decoded membership prevents LossyArray from hiding a schema mismatch.
    func send(_ endpoint: Endpoint<LibraryCollection>, as session: ContractSession) async throws -> LibraryCollection {
        let rawEndpoint = Endpoint<Data>(
            endpoint.method, endpoint.path, query: endpoint.query, headers: endpoint.headers,
            body: endpoint.body, requiresAuthentication: endpoint.requiresAuthentication)
        let response = try await session.client.response(for: rawEndpoint)
        #expect(response.httpResponse.statusCode == 200)
        let raw = try #require(JSONSerialization.jsonObject(with: response.value) as? [String: Any])
        let id = try #require(raw["id"] as? String)
        if endpoint.method == .post, endpoint.path == "/api/collections" {
            collectionIDs.append(id)
        }
        let collection = try JSONDecoder().decode(LibraryCollection.self, from: response.value)
        let books = try #require(raw["books"] as? [[String: Any]])
        #expect(collection.books?.count == books.count)
        #expect(collection.books?.map(\.id) == books.compactMap { $0["id"] as? String })
        return collection
    }

    func create(
        as session: ContractSession, books: [String]? = nil, name: String? = nil, libraryID: String? = nil
    ) async throws -> LibraryCollection {
        try await send(
            CollectionEndpoints.create(
                CollectionCreateRequest(
                    name: name ?? "collection-" + UUID().uuidString,
                    libraryID: libraryID ?? seed.bookLibraryID,
                    bookIDs: books ?? [seed.taleID, seed.singleFileID], description: "Initial description")),
            as: session)
    }

    func read(_ id: String, as session: ContractSession) async throws -> LibraryCollection {
        try await send(ItemEndpoints.collection(id: id), as: session)
    }

    func delete(_ id: String, as session: ContractSession) async throws {
        let response = try await session.client.response(for: CollectionEndpoints.delete(id: id))
        #expect(response.httpResponse.statusCode == 200)
        collectionIDs.removeAll { $0 == id }
    }

    func ownedIDs() -> (collections: [String], users: [String]) {
        (collectionIDs, userIDs)
    }

    private func cleanup() async -> [String] {
        var failures: [String] = []
        for id in collectionIDs.reversed() {
            do {
                _ = try await admin.client.send(CollectionEndpoints.delete(id: id))
            } catch {
                failures.append("collection \(id): \(error)")
            }
        }
        for id in userIDs.reversed() {
            do {
                _ = try await admin.client.send(Endpoint<EmptyResponse>(.delete, "/api/users/\(id)"))
            } catch {
                failures.append("user \(id): \(error)")
            }
        }
        return failures
    }

    private struct NewUser: Encodable, Sendable {
        let username: String
        let password: String
        let type = "user"
        let isActive = true
        let permissions: [String: Bool]?
        let librariesAccessible: [String]?
    }

    private struct CreatedUser: Decodable, Sendable {
        struct Identity: Decodable, Sendable { let id: String }
        let user: Identity
    }

    private struct CleanupFailure: Error {
        let resources: [String]
    }
}

func expectCollectionStatus<T>(
    _ status: Int, sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () async throws -> T
) async {
    let error = await #expect(throws: APIError.self, sourceLocation: sourceLocation) { try await operation() }
    switch error {
    case .forbidden where status == 403, .notFound where status == 404:
        return
    case .http(let actual, _) where actual == status:
        return
    default:
        Issue.record("Expected HTTP \(status), got \(String(describing: error))", sourceLocation: sourceLocation)
    }
}
