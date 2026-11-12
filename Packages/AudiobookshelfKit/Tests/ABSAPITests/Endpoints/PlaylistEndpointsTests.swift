import ABSCore
import Foundation
import Testing

@testable import ABSAPI

enum PlaylistWriteOperation: CaseIterable, Sendable {
    case create, update, delete, add, remove, removeItem

    func send(client: APIClient, id: String) async throws -> Playlist? {
        let items = [
            PlaylistItemReference(libraryItemID: "book"),
            PlaylistItemReference(libraryItemID: "podcast", episodeID: "episode"),
        ]
        switch self {
        case .create:
            return try await client.send(
                PlaylistEndpoints.create(PlaylistCreateRequest(name: "New", libraryID: "lib", items: items)))
        case .update:
            return try await client.send(
                PlaylistEndpoints.update(
                    id: id, PlaylistUpdateRequest(name: "Renamed", description: "", itemsInOrder: items)))
        case .delete:
            _ = try await client.send(PlaylistEndpoints.delete(id: id))
            return nil
        case .add:
            return try await client.send(PlaylistEndpoints.addItems(id: id, PlaylistItemsRequest(items: items)))
        case .remove:
            return try await client.send(PlaylistEndpoints.removeItems(id: id, PlaylistItemsRequest(items: items)))
        case .removeItem:
            return try await client.send(PlaylistEndpoints.removeItem(id: id, libraryItemID: "a/b", episodeID: "e p"))
        }
    }

    var method: String {
        switch self {
        case .create, .add, .remove: "POST"
        case .update: "PATCH"
        case .delete, .removeItem: "DELETE"
        }
    }

    var suffix: String {
        switch self {
        case .add: "/batch/add"
        case .remove: "/batch/remove"
        case .removeItem: "/item/a%2Fb/e%20p"
        default: ""
        }
    }
}

@Suite struct PlaylistEndpointsTests {
    @Test(
        arguments: PlaylistWriteOperation.allCases,
        [
            ("a/b?c#d%e f", "a%2Fb%3Fc%23d%25e%20f"), (".", "%2E"), ("..", "%2E%2E"),
        ])
    func factoriesThroughClient(operation: PlaylistWriteOperation, ids: (String, String)) async throws {
        let data = try playlistWriteFixture("2.37.2")
        let stub = StubServer { _ in
            operation == .delete ? .text("OK", status: 200) : StubResponse(status: 200, body: data)
        }
        let base = stub.baseURL.appendingPathComponent("proxy")
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: base),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())
        let value = try await operation.send(client: client, id: ids.0)
        if operation != .delete {
            #expect(value?.id == "playlist-book")
            #expect(value?.items.map(\.libraryItemId) == ["item-book0", "item-book1"])
        }
        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.httpMethod == operation.method)
        let path = "/api/playlists" + (operation == .create ? "" : "/\(ids.1)\(operation.suffix)")
        #expect(request.url?.absoluteString == base.absoluteString + path)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        if operation == .delete || operation == .removeItem {
            #expect(request.httpBody == nil)
        } else {
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(
                object["items"] as? [[String: String]] == [
                    ["libraryItemId": "book"], ["libraryItemId": "podcast", "episodeId": "episode"],
                ])
            switch operation {
            case .create:
                #expect(Set(object.keys) == ["name", "libraryId", "items"])
                #expect(object["name"] as? String == "New")
                #expect(object["libraryId"] as? String == "lib")
            case .update:
                #expect(Set(object.keys) == ["name", "description", "items"])
                #expect(object["name"] as? String == "Renamed")
                #expect(object["description"] as? String == "")
            default:
                #expect(Set(object.keys) == ["items"])
            }
        }
    }

    /// A nil or empty episode ID is a book: no trailing segment, which would be `/item/book/`.
    @Test(arguments: [nil, ""] as [String?])
    func removeItemOfABookHasNoEpisodeSegment(episodeID: String?) async throws {
        let data = try playlistWriteFixture("2.26.0")
        let stub = StubServer { _ in StubResponse(status: 200, body: data) }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())
        _ = try await client.send(PlaylistEndpoints.removeItem(id: "p", libraryItemID: "book", episodeID: episodeID))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == stub.baseURL.absoluteString + "/api/playlists/p/item/book")
        #expect(request.httpBody == nil)
    }

    /// A reorder sends only `items`, in the new order, each with its episode identity.
    @Test func reorderSendsOnlyTheItemsInTheirNewOrder() async throws {
        let data = try playlistWriteFixture("2.26.0")
        let stub = StubServer { _ in StubResponse(status: 200, body: data) }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())
        let order = [
            PlaylistItemReference(libraryItemID: "podcast", episodeID: "e2"),
            PlaylistItemReference(libraryItemID: "book"),
            PlaylistItemReference(libraryItemID: "podcast", episodeID: "e1"),
        ]
        _ = try await client.send(PlaylistEndpoints.update(id: "p", PlaylistUpdateRequest(itemsInOrder: order)))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.absoluteString == stub.baseURL.absoluteString + "/api/playlists/p")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["items"])
        #expect(
            object["items"] as? [[String: String]] == [
                ["libraryItemId": "podcast", "episodeId": "e2"], ["libraryItemId": "book"],
                ["libraryItemId": "podcast", "episodeId": "e1"],
            ])
    }

    @Test func optionalAndEmptyBodiesAreNotNormalized() async throws {
        let data = try playlistWriteFixture("2.26.0")
        let stub = StubServer { _ in StubResponse(status: 200, body: data) }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())
        _ = try await client.send(PlaylistEndpoints.update(id: "p", PlaylistUpdateRequest()))
        _ = try await client.send(PlaylistEndpoints.update(id: "p", PlaylistUpdateRequest(itemsInOrder: [])))
        _ = try await client.send(
            PlaylistEndpoints.create(
                PlaylistCreateRequest(name: "New", libraryID: "lib", items: [], description: "Description")))
        let objects = try stub.requests.map {
            let body = try #require($0.httpBody)
            return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        #expect(objects[0].isEmpty)
        #expect(Set(objects[1].keys) == ["items"])
        #expect(objects[1]["items"] as? [String] == [])
        #expect(Set(objects[2].keys) == ["name", "libraryId", "items", "description"])
        #expect(objects[2]["description"] as? String == "Description")
    }
}
