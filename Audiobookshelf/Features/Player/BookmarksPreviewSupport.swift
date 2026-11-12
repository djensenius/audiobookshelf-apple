import ABSAPI
import ABSAppModel
import ABSCore
import Foundation
import SwiftUI

/// A bookmark service for previews: answers at once from memory, or fails every write so the
/// error alert shows.
struct PreviewBookmarkService: BookmarkWriting, BookmarkReading {
    let bookmarks: [AudioBookmark]
    var failsWrites = false

    private struct Rejected: Error {}

    func createBookmark(itemID: String, time: Double, title: String) async throws -> AudioBookmark {
        guard !failsWrites else { throw Rejected() }
        return AudioBookmark(libraryItemId: itemID, title: title, time: time)
    }

    func renameBookmark(itemID: String, time: Double, title: String) async throws -> AudioBookmark {
        guard !failsWrites else { throw Rejected() }
        return AudioBookmark(libraryItemId: itemID, title: title, time: time)
    }

    func deleteBookmark(itemID: String, time: Double) async throws {
        guard !failsWrites else { throw Rejected() }
    }

    func allBookmarks() async throws -> [AudioBookmark] { bookmarks }
}

extension [AudioBookmark] {
    /// Three bookmarks in the preview book (``PlayerViewModel/preview(loaded:at:playing:buffering:)``),
    /// one at its default position, 4,000 seconds, so it shows highlighted.
    static var previewFixtures: [AudioBookmark] {
        [
            AudioBookmark(libraryItemId: "li_preview", title: "The spice must flow", time: 4_000),
            AudioBookmark(libraryItemId: "li_preview", title: "Fear is the mind-killer", time: 125),
            AudioBookmark(libraryItemId: "li_preview", title: "The sleeper must awaken", time: 9_310),
        ]
    }
}

/// Shows `content` over a preview player with a ``BookmarkStore`` in the environment, whose
/// session uses a ``PreviewBookmarkService`` holding `bookmarks`.
struct BookmarksPreviewHost<Content: View>: View {
    @State private var model = PlayerViewModel.preview()
    @State private var store: BookmarkStore
    @State private var isReady = false
    private let bookmarks: [AudioBookmark]
    private let isAvailable: Bool
    private let content: (PlayerViewModel) -> Content

    /// - Parameter isAvailable: `false` starts the session offline, as without a connection (D11).
    init(
        bookmarks: [AudioBookmark], isAvailable: Bool = true, failsWrites: Bool = false,
        @ViewBuilder content: @escaping (PlayerViewModel) -> Content
    ) {
        let service = PreviewBookmarkService(bookmarks: bookmarks, failsWrites: failsWrites)
        _store = State(initialValue: BookmarkStore(makeService: { _ in service }))
        self.bookmarks = bookmarks
        self.isAvailable = isAvailable
        self.content = content
    }

    var body: some View {
        Group {
            if isReady {
                content(model)
                    .environment(\.bookmarkStore, store)
            }
        }
        .task {
            guard !isReady else { return }
            await store.sessionDidStart(Self.context(isOffline: !isAvailable))
            store.replaceAll(from: User(id: "preview", username: "preview", bookmarks: bookmarks))
            isReady = true
        }
    }

    /// A session whose client is never used: the store's service is the preview one.
    private static func context(isOffline: Bool) -> SessionContext {
        let client = APIClient(
            configuration: try! APIClientConfiguration(baseURL: URL(string: "https://abs.example")!),
            tokenProvider: PreviewTokens())
        return SessionContext(
            identity: SessionIdentity(connectionID: UUID(), userID: "preview"), client: client, isOffline: isOffline,
            sessionID: 1)
    }
}

/// Signed out: previews never send a request.
private struct PreviewTokens: TokenProvider {
    func tokens() async -> AuthTokens? { nil }
    func replaceTokens(expected: AuthTokens, with new: AuthTokens) async -> Bool { false }
    func expireSession(ifCurrent rejected: AuthTokens) async -> Bool { false }
}
