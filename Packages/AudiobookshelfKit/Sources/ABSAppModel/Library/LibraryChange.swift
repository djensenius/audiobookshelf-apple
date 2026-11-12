import ABSCore
import ABSRealtime
import Foundation

/// A change to a library's entities pushed by the server's socket, which ``RealtimeBridge``
/// hands to ``LibraryStore/applyLibraryChange(_:connectionKey:)`` for the screens showing them.
/// Each entity kind the screens follow gets a case.
public enum LibraryChange: Sendable, Hashable {
    case author(LibraryEntityChange<Author>)
    case collection(LibraryEntityChange<LibraryCollection>)
    /// `userID` is the playlist's owner; screens ignore other users' playlists, as legacy does.
    case playlist(LibraryEntityChange<Playlist>, userID: String)

    public var libraryID: String {
        switch self {
        case .author(let change): change.libraryID
        case .collection(let change): change.libraryID
        case .playlist(let change, _): change.libraryID
        }
    }
}
