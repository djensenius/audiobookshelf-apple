import ABSCore
import ABSRealtime
import Foundation

/// A change to a library's entities pushed by the server's socket, which ``RealtimeBridge``
/// hands to ``LibraryStore/applyLibraryChange(_:connectionKey:)`` for the screens showing them.
/// Each entity kind the screens follow gets a case.
public enum LibraryChange: Sendable, Hashable {
    case author(LibraryEntityChange<Author>)

    public var libraryID: String {
        switch self {
        case .author(let change): change.libraryID
        }
    }
}
