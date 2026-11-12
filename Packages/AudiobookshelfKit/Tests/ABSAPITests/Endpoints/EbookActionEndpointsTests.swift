import ABSCore
import Foundation
import Testing

@testable import ABSAPI

private func url<Response>(_ endpoint: Endpoint<Response>) throws -> String {
    let base = try #require(URL(string: "https://abs.example/abs"))
    return try APIClient.url(base: base, path: endpoint.path, query: endpoint.query).absoluteString
}

private func json<Response>(_ endpoint: Endpoint<Response>) throws -> [String: Any] {
    let body = try #require(endpoint.body)
    return try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
}

private func json(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func makeClient(_ stub: StubServer) throws -> APIClient {
    APIClient(
        configuration: try APIClientConfiguration(baseURL: stub.baseURL),
        tokenProvider: InMemoryTokenProvider(),
        sessionConfiguration: stub.sessionConfiguration()
    )
}

private let server = "https://abs.example/abs"

/// Send ebook to device (`EmailEndpoints`) and the ebook file status toggle (`ItemEndpoints`).
@Suite struct EbookActionEndpointsTests {
    @Test func sendEbookToDevice() throws {
        let endpoint = EmailEndpoints.sendEbookToDevice(libraryItemID: "li1", deviceName: "Kindle")
        #expect(endpoint.method == .post)
        #expect(endpoint.requiresAuthentication)
        #expect(endpoint.followsRedirects && endpoint.staysOnOrigin)
        #expect(try url(endpoint) == "\(server)/api/emails/send-ebook-to-device")
        let body = try json(endpoint)
        #expect(Set(body.keys) == ["libraryItemId", "deviceName"])
        #expect(body["libraryItemId"] as? String == "li1")
        #expect(body["deviceName"] as? String == "Kindle")
    }

    @Test func toggleEbookFileStatus() throws {
        let endpoint = ItemEndpoints.toggleEbookFileStatus(itemID: "li1", fileID: "12345")
        #expect(endpoint.method == .patch)
        #expect(endpoint.requiresAuthentication)
        #expect(endpoint.body == nil)
        #expect(try url(endpoint) == "\(server)/api/items/li1/ebook/12345/status")
    }

    @Test func toggleEncodesIDsAsOnePathSegment() throws {
        #expect(
            try url(ItemEndpoints.toggleEbookFileStatus(itemID: "a/b", fileID: "c/d"))
                == "\(server)/api/items/a%2Fb/ebook/c%2Fd/status")
    }

    @Test func clientSendsEbookToDevice() async throws {
        let stub = StubServer { _ in .text("OK", status: 200) }
        _ = try await makeClient(stub).send(
            EmailEndpoints.sendEbookToDevice(libraryItemID: "li1", deviceName: "Kobo Libra"))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/abs/api/emails/send-ebook-to-device")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try json(request.httpBody)
        #expect(body["libraryItemId"] as? String == "li1")
        #expect(body["deviceName"] as? String == "Kobo Libra")
    }

    /// A 307 or 308 to another origin isn't followed, so the item and device aren't re-posted
    /// there and its reply isn't taken for a send; one on the server's origin still is.
    @Test(arguments: [307, 308]) func clientRefusesCrossOriginSendRedirect(status: Int) async throws {
        let other = StubServer { _ in .text("OK", status: 200) }
        let origin = StubServer { _ in .redirect(to: "https://\(other.host)/x", status: status) }
        await #expect(throws: APIError.redirectRefused(status: status)) {
            try await makeClient(origin).send(
                EmailEndpoints.sendEbookToDevice(libraryItemID: "li1", deviceName: "Kindle"))
        }
        #expect(other.requests.isEmpty)

        let sameOrigin = StubServer { request in
            request.url?.path() == "/abs/api/emails/send-ebook-to-device"
                ? .redirect(to: "https://\(request.url?.host() ?? "")/abs/moved", status: status)
                : .text("OK", status: 200)
        }
        _ = try await makeClient(sameOrigin).send(
            EmailEndpoints.sendEbookToDevice(libraryItemID: "li1", deviceName: "Kindle"))
        #expect(try json(sameOrigin.requests(path: "/abs/moved").first?.httpBody)["deviceName"] as? String == "Kindle")
    }

    /// The mailer's error text (server `EmailManager.sendEBookToDevice`) reaches the caller.
    @Test func clientSurfacesSendFailureText() async throws {
        let stub = StubServer { _ in .text("Invalid login", status: 400) }
        await #expect(throws: APIError.http(status: 400, message: "Invalid login")) {
            try await makeClient(stub).send(EmailEndpoints.sendEbookToDevice(libraryItemID: "li1", deviceName: "K"))
        }
    }

    @Test func clientTogglesEbookFileStatus() async throws {
        let stub = StubServer { _ in .text("OK", status: 200) }
        _ = try await makeClient(stub).send(ItemEndpoints.toggleEbookFileStatus(itemID: "li1", fileID: "42"))
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path() == "/abs/api/items/li1/ebook/42/status")
        #expect(request.httpBody == nil)
    }

    @Test func clientToggleWithoutUpdatePermissionIsForbidden() async throws {
        let stub = StubServer { _ in .text("Forbidden", status: 403) }
        await #expect(throws: APIError.forbidden(message: "Forbidden")) {
            try await makeClient(stub).send(ItemEndpoints.toggleEbookFileStatus(itemID: "li1", fileID: "42"))
        }
    }
}
