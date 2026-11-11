import ABSAPI
import Foundation
import Testing

@Suite(
    "Server contract: isolated owned search", .serialized, .tags(.serverContract),
    .enabled(
        if: ProcessInfo.processInfo.environment["ABS_SEARCH_CONTRACT_MODE"] != nil,
        "Owned search NOT RUN: use scripts/test-server.sh test --search-contract; package skips are not evidence"))
struct SearchContractTests {
    @Test("all search groups plus positive book filters and podcast tags/genres match owned fixtures")
    func completeSearch() async throws {
        try await SearchContractFixture.withFixture { fixture, ledger, user in
            for podcast in [false, true] {
                let library = podcast ? ledger.podcastLibrary : ledger.bookLibrary
                let label = podcast ? "podcast" : "book"
                let detail = LibraryEndpoints.library(id: library)
                let wrapper = try await fixture.request(
                    detail.path, query: detail.query, as: user, captureLabel: "\(label)-filter-wrapper")
                let dedicated = try await fixture.request(
                    "/api/libraries/\(library)/filterdata", as: user, captureLabel: "\(label)-filter-dedicated")
                let configuration = fixture.configuration
                _ = try SearchFilterRaw.positivePair(
                    wrapper: wrapper, dedicated: dedicated, ledger: ledger, podcast: podcast,
                    version: configuration.version, folder: podcast ? configuration.podcasts : configuration.books)
                let endpoint = LibraryEndpoints.search(libraryID: library, query: ledger.token)
                let data = try await fixture.request(endpoint.path, query: endpoint.query, as: user)
                try await fixture.capture(data, label: podcast ? "podcast-search" : "book-search")
                _ = try SearchRaw.search(data, ledger: ledger, podcast: podcast)
            }
        }
    }

    @Test("CHARACTERIZATION: scan-primed podcast language is missing; nonempty acceptance #263 remains open")
    func scanPrimedPodcastLanguageDiscrepancy() async throws {
        try await SearchContractFixture.withFixture { fixture, ledger, user in
            let endpoint = LibraryEndpoints.library(id: ledger.podcastLibrary)
            let wrapper = try await fixture.request(
                endpoint.path, query: endpoint.query, as: user, captureLabel: "podcast-language-wrapper")
            let dedicated = try await fixture.request(
                "/api/libraries/\(ledger.podcastLibrary)/filterdata", as: user,
                captureLabel: "podcast-language-dedicated")
            let configuration = fixture.configuration
            let result = try SearchFilterRaw.positivePair(
                wrapper: wrapper, dedicated: dedicated, ledger: ledger, podcast: true,
                version: configuration.version, folder: configuration.podcasts)
            let itemLanguage = try #require(ledger.podcast.podcast?.metadata.language)
            #expect(itemLanguage == "de")
            #expect(result.filterData.languages == [])
            #expect(!result.filterData.languages.contains(itemLanguage))
            // This pins an observed server omission, NOT a passing nonempty-language contract.
            // Both cold queries support language; no cache expiry/reload or workaround is exercised.
        }
    }

    @Test("bounded read-only limits, absent matches and query errors preserve request semantics")
    func queries() async throws {
        try await SearchContractFixture.withFixture { fixture, ledger, user in
            for podcast in [false, true] {
                let library = podcast ? ledger.podcastLibrary : ledger.bookLibrary
                for limit in [1, 0, 12] {
                    let query = " \(ledger.token) "
                    let endpoint = LibraryEndpoints.search(libraryID: library, query: query, limit: limit)
                    #expect(endpoint.query.first?.value == query)
                    let data = try await fixture.request(endpoint.path, query: endpoint.query, as: user)
                    try await fixture.capture(data, label: "search-limit-\(podcast)-\(limit)")
                    _ = try SearchRaw.search(data, ledger: ledger, podcast: podcast, limit: limit)
                }
                let endpoint = LibraryEndpoints.search(libraryID: library, query: "absent" + UUID().uuidString)
                let data = try await fixture.request(endpoint.path, query: endpoint.query, as: user)
                try await fixture.capture(data, label: "no-matches")
                _ = try SearchRaw.search(data, ledger: ledger, podcast: podcast, empty: true)
                await expectNotFound {
                    try await user.client.send(
                        LibraryEndpoints.search(libraryID: UUID().uuidString, query: ledger.token))
                }
                for query in [[], [URLQueryItem(name: "q", value: "")]] {
                    let error = await #expect(throws: APIError.self) {
                        try await fixture.request("/api/libraries/\(library)/search", query: query, as: user)
                    }
                    guard case .http(let status, _) = error else {
                        Issue.record("Expected empty/missing q to return HTTP 400, got \(String(describing: error))")
                        continue
                    }
                    #expect(status == 400)
                }
            }
        }
    }

    @Test("deliberate body error preserves primary failure and verifies exact-ID cascade cleanup")
    func failureCleanup() async throws {
        struct Deliberate: Error { let paths: [String] }
        do {
            try await SearchContractFixture.withFixture { fixture, _, _ in
                throw Deliberate(paths: await fixture.ownedPaths())
            }
            Issue.record("The body error was swallowed")
        } catch let error as Deliberate {
            let admin = try await ContractAdmin.shared.session()
            #expect(!error.paths.isEmpty)
            for path in error.paths {
                await expectNotFound { try await admin.client.send(Endpoint<Data>(.get, path, timeout: 5)) }
            }
        }
    }
}
