import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// A search request a ``FakeSearchService`` received.
struct SearchRequest: Sendable, Equatable {
    let libraryID: String
    let query: String
    let limit: Int?
}

/// A ``SearchService`` whose responses come from a closure.
struct FakeSearchService: SearchService {
    var handler: @Sendable (SearchRequest) async throws -> LibrarySearchResults

    func searchLibrary(id: String, query: String, limit: Int?) async throws -> LibrarySearchResults {
        try await handler(SearchRequest(libraryID: id, query: query, limit: limit))
    }
}

func decodeSearch(_ json: String) throws -> LibrarySearchResults {
    try JSONDecoder().decode(LibrarySearchResults.self, from: Data(json.utf8))
}

let searchBook = #"{"id":"li1","libraryId":"lib","mediaType":"book","media":{"id":"b1","metadata":{"title":"One"}}}"#
let searchPodcast =
    #"{"id":"li2","libraryId":"pods","mediaType":"podcast","media":{"id":"p1","metadata":{"title":"Pod"}}}"#
let searchEpisode =
    #"{"id":"li2","libraryId":"pods","mediaType":"podcast","media":{"id":"p1","metadata":{"title":"Pod"}},"#
    + #""recentEpisode":{"id":"ep7","libraryItemId":"li2","title":"Match"}}"#

/// Results with one book titled `title`.
func bookResults(_ id: String, title: String = "Title") throws -> LibrarySearchResults {
    try decodeSearch(
        #"{"book":[{"libraryItem":{"id":"\#(id)","libraryId":"lib","mediaType":"book","media":{"id":"b","metadata":{"title":"\#(title)"}}}}]}"#
    )
}
