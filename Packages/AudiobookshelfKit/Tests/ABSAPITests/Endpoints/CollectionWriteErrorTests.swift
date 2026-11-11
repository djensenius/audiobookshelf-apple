import Foundation
import Testing

@testable import ABSAPI

@Suite struct CollectionWriteErrorTests {
    @Test(arguments: CollectionWriteOperation.allCases, [400, 403, 404, 500])
    func preservesHTTPFailures(operation: CollectionWriteOperation, status: Int) async throws {
        let stub = StubServer { _ in .text("Collection error", status: status) }
        let tokens = InMemoryTokenProvider()
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: tokens, sessionConfiguration: stub.sessionConfiguration())
        let error = await #expect(throws: APIError.self) {
            try await operation.send(client: client, id: "c")
        }
        let expected: APIError =
            switch status {
            case 403: .forbidden(message: "Collection error")
            case 404: .notFound
            default: .http(status: status, message: "Collection error")
            }
        #expect(error == expected)
        #expect(stub.requests.count == 1)
        #expect(tokens.updates.isEmpty)
        #expect(tokens.expiredCount == 0)
    }

    @Test(arguments: CollectionWriteOperation.allCases)
    func missingCredentialsNeverSend(operation: CollectionWriteOperation) async throws {
        let stub = StubServer { _ in .text("Must not send", status: 500) }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(nil), sessionConfiguration: stub.sessionConfiguration())
        await #expect(throws: APIError.notAuthenticated) {
            try await operation.send(client: client, id: "c")
        }
        #expect(stub.requests.isEmpty)
    }

    @Test(
        arguments: [
            CollectionWriteOperation.create, .update, .add, .remove,
        ], ["not JSON", "{}", #"{"collection":{"id":"c","libraryId":"l","name":"Wrapped"}}"#])
    func malformedSuccessIsDecodingFailure(operation: CollectionWriteOperation, body: String) async throws {
        let stub = StubServer { _ in .json(body) }
        let client = APIClient(
            configuration: try APIClientConfiguration(baseURL: stub.baseURL),
            tokenProvider: InMemoryTokenProvider(), sessionConfiguration: stub.sessionConfiguration())
        let error = await #expect(throws: APIError.self) {
            try await operation.send(client: client, id: "c")
        }
        guard case .decoding? = error else {
            Issue.record("Expected decoding failure, got \(String(describing: error))")
            return
        }
    }
}
