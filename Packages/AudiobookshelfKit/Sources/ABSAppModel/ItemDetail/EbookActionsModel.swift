import ABSAPI
import ABSCore
import Foundation
import Observation

/// Sends a book's ebook to an e-reader and changes which ebook file is primary; `APIClient`
/// conforms.
public protocol EbookActionsService: Sendable {
    /// Emails the item's primary ebook to the e-reader device named `deviceName`.
    func sendEbookToDevice(itemID: String, deviceName: String) async throws
    /// Makes the ebook file with inode `fileID` primary if it's supplementary, else supplementary.
    func toggleEbookFileStatus(itemID: String, fileID: String) async throws
}

extension APIClient: EbookActionsService {
    public func sendEbookToDevice(itemID: String, deviceName: String) async throws {
        _ = try await send(EmailEndpoints.sendEbookToDevice(libraryItemID: itemID, deviceName: deviceName))
    }

    public func toggleEbookFileStatus(itemID: String, fileID: String) async throws {
        _ = try await send(ItemEndpoints.toggleEbookFileStatus(itemID: itemID, fileID: fileID))
    }
}

/// The book More menu's ebook actions: Send ebook to device (legacy `ItemMoreMenuModal.vue`) and,
/// like the web client's ebook files table, Set as primary / Set as supplementary.
///
/// Gating, from the signed-in user's ``AuthResponse``:
/// - Send to device needs a primary ebook (the server only sends `media.ebookFile`) and at least
///   one device in ``AuthResponse/ereaderDevices``, which the server already limits to the
///   devices this user may use.
/// - Changing a file's status needs the update permission on an active user (server
///   `User.canUpdate`); the server answers 403 otherwise.
/// - Neither is offered once the item is gone from the server.
///
/// One action runs at a time (``isBusy``); each returns an ``Outcome`` for the view to show and
/// announce. After a status change, the caller reloads the item to show the new primary file.
@MainActor
@Observable
public final class EbookActionsModel {
    /// A file's status change, as the menu offers it.
    public struct StatusChange: Sendable, Hashable, Identifiable {
        /// The file's inode, ``ItemDetailModel/EbookFileRow/id``.
        public let id: String
        /// May be empty when the server sent no file metadata.
        public let filename: String
        /// The change makes the file primary; otherwise it makes the primary file supplementary.
        public let makesPrimary: Bool

        public init(id: String, filename: String, makesPrimary: Bool) {
            self.id = id
            self.filename = filename
            self.makesPrimary = makesPrimary
        }

        /// `LabelSetEbookAsPrimary` or `LabelSetEbookAsSupplementary`.
        public var titleKey: String {
            makesPrimary ? "LabelSetEbookAsPrimary" : "LabelSetEbookAsSupplementary"
        }
    }

    /// What an action ended with.
    public enum Outcome: Sendable, Hashable {
        /// The server accepted the ebook for `deviceName`.
        case sent(deviceName: String)
        /// The file's status changed as `change` asked.
        case statusChanged(StatusChange)
        /// The send failed. `message` is the server's text, if it sent one.
        case sendFailed(deviceName: String, message: String?)
        /// The status change failed. `message` is the server's text, if it sent one.
        case statusChangeFailed(message: String?)
        /// Another action was running; nothing was sent.
        case ignored
    }

    public let itemID: String
    /// An action is in flight; the menu disables the ebook entries meanwhile.
    public private(set) var isBusy = false

    @ObservationIgnored private let service: any EbookActionsService

    public init(itemID: String, service: any EbookActionsService) {
        self.itemID = itemID
        self.service = service
    }

    // MARK: Gating

    /// The devices to offer for Send ebook to device, in the server's order; empty when it isn't
    /// offered.
    public static func devices(
        authorization: AuthResponse?, ebookFiles: [ItemDetailModel.EbookFileRow], isGone: Bool
    ) -> [EReaderDevice] {
        guard !isGone, ebookFiles.contains(where: \.isPrimary) else { return [] }
        return (authorization?.ereaderDevices ?? []).filter { !$0.name.isEmpty }
    }

    /// The status changes to offer, one per ebook file in `ebookFiles` order; empty without the
    /// update permission.
    public static func statusChanges(
        authorization: AuthResponse?, ebookFiles: [ItemDetailModel.EbookFileRow], isGone: Bool
    ) -> [StatusChange] {
        guard !isGone, let user = authorization?.user, user.permissions.update, user.isActive else { return [] }
        return ebookFiles.map { StatusChange(id: $0.id, filename: $0.filename, makesPrimary: !$0.isPrimary) }
    }

    // MARK: Actions

    /// Sends the primary ebook to `deviceName`.
    public func send(to deviceName: String) async -> Outcome {
        guard !isBusy else { return .ignored }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.sendEbookToDevice(itemID: itemID, deviceName: deviceName)
            return .sent(deviceName: deviceName)
        } catch {
            return .sendFailed(deviceName: deviceName, message: Self.serverMessage(error))
        }
    }

    /// Applies `change`; the caller reloads the item on success.
    public func apply(_ change: StatusChange) async -> Outcome {
        guard !isBusy else { return .ignored }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.toggleEbookFileStatus(itemID: itemID, fileID: change.id)
            return .statusChanged(change)
        } catch {
            return .statusChangeFailed(message: Self.serverMessage(error))
        }
    }

    /// The plain text the server sent with a failure, if any. A 404's text isn't kept by
    /// ``APIError/notFound``.
    static func serverMessage(_ error: any Error) -> String? {
        switch error as? APIError {
        case .http(_, let message), .forbidden(let message), .unauthorized(let message): message
        default: nil
        }
    }
}
