import Foundation
import Testing

/// Validated before login or any fixture mutation. This is permission from the disposable harness,
/// not an inference that a manually configured server is safe to mutate.
struct SearchContractConfiguration: Sendable {
    let address: String
    let version: String
    let books: String
    let podcasts: String
    let token: String
    let provenance: Data
    let captureDirectory: URL?

    struct Invalid: Error, CustomStringConvertible {
        let description: String
    }

    init(_ env: [String: String] = ProcessInfo.processInfo.environment) throws {
        func required(_ key: String) throws -> String {
            guard let value = env[key], !value.isEmpty else { throw Invalid(description: "Missing \(key)") }
            return value
        }
        guard try required("ABS_SEARCH_CONTRACT_MODE") == "1" else {
            throw Invalid(description: "Invalid explicit search mode")
        }
        address = try required("ABS_SEARCH_OWNED_URL")
        guard try required("ABS_TEST_SERVER_URL") == address,
            let url = URLComponents(string: address), url.scheme == "http", url.host == "127.0.0.1",
            let port = url.port, (1...65535).contains(port),
            address == "http://127.0.0.1:\(port)"
        else { throw Invalid(description: "Configured URL must exactly match the harness-owned loopback URL") }
        _ = try required("ABS_TEST_USERNAME")
        _ = try required("ABS_TEST_PASSWORD")
        token = try required("ABS_SEARCH_TOKEN")
        guard token.range(of: "^search[0-9a-f]{16}$", options: .regularExpression) != nil,
            try required("ABS_SEARCH_OWNERSHIP") == token
        else { throw Invalid(description: "Missing or malformed harness ownership") }
        books = try required("ABS_SEARCH_BOOKS")
        podcasts = try required("ABS_SEARCH_PODCASTS")
        let root = String(books.dropLast("/books".count))
        guard books.hasSuffix("/search-fixtures/books"), podcasts == root + "/casts",
            root.hasPrefix("/"), !root.contains("//"), !root.contains("/../"), !root.contains("/./"),
            !root.contains("\n"), !root.contains("\0")
        else { throw Invalid(description: "Invalid server-visible owned fixture folders") }
        version = try required("ABS_TEST_SERVER_VERSION")
        let revisions = [
            "2.26.0": "264ae928a9c1af620487488110eec816b14e23ec",
            "2.37.2": "edb1f7efc92ecacdef51aafb4d9d5054ce10604f",
        ]
        provenance = Data(try required("ABS_SEARCH_PROVENANCE").utf8)
        guard let pin = revisions[version],
            let record = try JSONSerialization.jsonObject(with: provenance) as? [String: Any],
            record["revision"] as? String == pin
        else { throw Invalid(description: "Missing or mismatching exact source provenance") }
        switch record["backend"] as? String {
        case "docker":
            let digests = [
                "2.26.0": "sha256:16685fbba37a21d403f5390b907d286e15b3086d26527269b4ad785f71f571e5",
                "2.37.2": "sha256:b897c33f05972fb1bf484f7487bc878fa91ec8691335c1db6e2929c3a7658efa",
            ]
            guard root == "/search-fixtures",
                let labels = record["labels"] as? [String: String],
                labels["org.opencontainers.image.revision"] == pin,
                labels["org.opencontainers.image.version"] == version,
                labels["org.opencontainers.image.source"] == "https://github.com/advplyr/audiobookshelf",
                (record["digests"] as? [String])?.contains(
                    "ghcr.io/advplyr/audiobookshelf@" + (digests[version] ?? "")) == true
            else { throw Invalid(description: "Invalid official Docker provenance") }
        case "node":
            guard record["checkoutClean"] as? Bool == true,
                books.contains("/abs-contract.")
            else { throw Invalid(description: "Invalid node checkout/folder provenance") }
        default: throw Invalid(description: "Unknown owned backend")
        }
        if let path = env["ABS_SEARCH_LIVE_CAPTURE_DIR"] {
            // SwiftPM runs the executable from the package, not the harness's working directory.
            var worktree = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { worktree.deleteLastPathComponent() }
            let build = worktree.appendingPathComponent(".build").resolvingSymlinksInPath().path
            let capture = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard path.hasPrefix("/"), capture.path.hasPrefix(build + "/") else {
                throw Invalid(description: "Search capture directory must be inside this worktree's .build")
            }
            captureDirectory = capture.appendingPathComponent(UUID().uuidString)
        } else {
            captureDirectory = nil
        }
    }
}

@Suite("Owned search gate (no network or writes)")
struct SearchContractGateTests {
    private var valid: [String: String] {
        [
            "ABS_SEARCH_CONTRACT_MODE": "1", "ABS_SEARCH_OWNED_URL": "http://127.0.0.1:12345",
            "ABS_TEST_SERVER_URL": "http://127.0.0.1:12345", "ABS_TEST_USERNAME": "root",
            "ABS_TEST_PASSWORD": "synthetic-not-a-credential", "ABS_SEARCH_TOKEN": "search0123456789abcdef",
            "ABS_SEARCH_OWNERSHIP": "search0123456789abcdef", "ABS_TEST_SERVER_VERSION": "2.26.0",
            "ABS_SEARCH_BOOKS": "/tmp/abs-contract.synthetic/search-fixtures/books",
            "ABS_SEARCH_PODCASTS": "/tmp/abs-contract.synthetic/search-fixtures/casts",
            "ABS_SEARCH_PROVENANCE":
                #"{"backend":"node","revision":"264ae928a9c1af620487488110eec816b14e23ec","checkoutClean":true}"#,
        ]
    }

    @Test("every required input fails closed when absent or empty")
    func missingInputs() throws {
        _ = try SearchContractConfiguration(valid)
        for key in valid.keys {
            var input = valid
            input.removeValue(forKey: key)
            #expect(throws: (any Error).self) { try SearchContractConfiguration(input) }
            input[key] = ""
            #expect(throws: (any Error).self) { try SearchContractConfiguration(input) }
        }
    }

    @Test("mode, ownership, URL, paths and provenance cannot be reinterpreted")
    func malformedInputs() {
        for (key, value) in [
            ("ABS_SEARCH_CONTRACT_MODE", "true"), ("ABS_SEARCH_OWNERSHIP", "other"),
            ("ABS_SEARCH_TOKEN", "search/unsafe"), ("ABS_TEST_SERVER_URL", "http://127.0.0.1:12346"),
            ("ABS_SEARCH_OWNED_URL", "https://example.com"), ("ABS_SEARCH_BOOKS", "/audiobooks-search"),
            ("ABS_SEARCH_PODCASTS", "/podcasts/owned"), ("ABS_TEST_SERVER_VERSION", "2.99.0"),
            ("ABS_SEARCH_PROVENANCE", "{}"),
        ] {
            var input = valid
            input[key] = value
            #expect(throws: (any Error).self) { try SearchContractConfiguration(input) }
        }
    }
}
