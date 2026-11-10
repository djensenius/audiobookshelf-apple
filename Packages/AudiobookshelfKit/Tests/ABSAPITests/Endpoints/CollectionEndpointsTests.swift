import ABSCore
import Foundation
import Testing

@testable import ABSAPI

/// Shared only by the collection endpoint/error tests; sends the actual typed factories.
enum CollectionWriteOperation: CaseIterable, Sendable {
    case create, update, delete, add, remove

    func send(client: APIClient, id: String) async throws -> LibraryCollection? {
        switch self {
        case .create:
            return try await client.send(
                CollectionEndpoints.create(
                    CollectionCreateRequest(name: "New", libraryID: "lib", bookIDs: ["item-2", "item-1"])))
        case .update:
            return try await client.send(
                CollectionEndpoints.update(
                    id: id,
                    CollectionUpdateRequest(name: "Renamed", description: "", bookIDsInOrder: ["item-2", "item-1"])))
        case .delete:
            _ = try await client.send(CollectionEndpoints.delete(id: id))
            return nil
        case .add:
            return try await client.send(
                CollectionEndpoints.addBooks(id: id, CollectionBooksRequest(bookIDs: ["item-2", "item-1"])))
        case .remove:
            return try await client.send(
                CollectionEndpoints.removeBooks(id: id, CollectionBooksRequest(bookIDs: ["item-2", "item-1"])))
        }
    }

    var method: String {
        switch self {
        case .create, .add, .remove: "POST"
        case .update: "PATCH"
        case .delete: "DELETE"
        }
    }

    var suffix: String {
        switch self {
        case .add: "/batch/add"
        case .remove: "/batch/remove"
        default: ""
        }
    }
}

@Suite struct CollectionEndpointsTests {
    @Test(
        arguments: CollectionWriteOperation.allCases,
        [
            ("a/b?c#d%e f", "a%2Fb%3Fc%23d%25e%20f"), (".", "%2E"), ("..", "%2E%2E"),
        ])
    func factoriesThroughClient(operation: CollectionWriteOperation, ids: (String, String)) async throws {
        let data = try collectionWriteFixture("2.37.2")
        let stub = StubServer { _ in
            operation == .delete
                ? .text("OK", status: 200)
                : StubResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
        }
        let base = stub.baseURL.appendingPathComponent("proxy")
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: base),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())
        let value = try await operation.send(client: client, id: ids.0)
        if operation != .delete {
            #expect(value?.id == "collection-fixture")
            #expect(value?.books?.map(\.id) == ["item-tale", "item-single"])
        }
        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.httpMethod == operation.method)
        let path = "/api/collections" + (operation == .create ? "" : "/\(ids.1)\(operation.suffix)")
        #expect(request.url?.absoluteString == base.absoluteString + path)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        if operation == .delete {
            #expect(request.httpBody == nil)
        } else {
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["books"] as? [String] == ["item-2", "item-1"])
            switch operation {
            case .create:
                #expect(Set(object.keys) == ["name", "libraryId", "books"])
                #expect(object["name"] as? String == "New")
                #expect(object["libraryId"] as? String == "lib")
            case .update:
                #expect(Set(object.keys) == ["name", "description", "books"])
                #expect(object["name"] as? String == "Renamed")
                #expect(object["description"] as? String == "")
            default:
                #expect(Set(object.keys) == ["books"])
            }
        }
    }

    @Test func optionalAndEmptyBodiesAreNotNormalized() async throws {
        let data = try collectionWriteFixture("2.26.0")
        let stub = StubServer { _ in StubResponse(status: 200, body: data) }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())
        _ = try await client.send(CollectionEndpoints.update(id: "c", CollectionUpdateRequest()))
        _ = try await client.send(CollectionEndpoints.update(id: "c", CollectionUpdateRequest(bookIDsInOrder: [])))
        _ = try await client.send(
            CollectionEndpoints.create(
                CollectionCreateRequest(name: "New", libraryID: "lib", bookIDs: ["i"], description: "Description")))
        let objects = try stub.requests.map {
            let body = try #require($0.httpBody)
            return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        #expect(objects[0].isEmpty)
        #expect(Set(objects[1].keys) == ["books"])
        #expect(objects[1]["books"] as? [String] == [])
        #expect(Set(objects[2].keys) == ["name", "libraryId", "books", "description"])
        #expect(objects[2]["description"] as? String == "Description")
    }
}
