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
/// Gating, from the signed-in user's ``AuthResponse`` and the loaded item:
/// - Send to device needs a primary ebook (`media.ebookFile`, the only file the server sends)
///   and at least one device in ``AuthResponse/ereaderDevices``, which the server already limits
///   to the devices this user may use.
/// - Changing a file's status needs the update permission on an active user (server
///   `User.canUpdate`; 403 otherwise), a book, and a file with an inode. The server flips the
///   file's own `isSupplementary` (`LibraryItemController.updateEbookFileStatus`), so that, not
///   `media.ebookFile`, says which way a change goes; the two disagree on legacy data.
/// - ``offeredStatusChanges(authorization:item:isGone:)`` stays empty after a change whose reload
///   failed (``needsReload``), until the item loads again (``itemDidLoad()``), so it never offers
///   the pre-change direction.
/// - Neither is offered once the item is gone from the server.
///
/// One action runs at a time (``isBusy``), a status change through its reload. A tap is checked
/// against the devices or changes offered at that moment and dropped if the item changed meanwhile. Each
/// action returns an ``Outcome`` for the view to show and announce.
///
/// The model belongs to one item model, not one client: a reconnect to the same account swaps
/// the client in with ``replaceService(_:)``, keeping ``isBusy`` and ``needsReload``, so the
/// reconnect neither re-offers a stale change nor lets a new action overlap one in flight.
@MainActor
@Observable
public final class EbookActionsModel {
    /// A file's status change, as the menu offers it.
    public struct StatusChange: Sendable, Hashable, Identifiable {
        /// The file's inode, ``LibraryFile/ino``.
        public let id: String
        /// May be empty when the server sent no file metadata.
        public let filename: String
        /// The change makes the file primary; otherwise it makes the file supplementary.
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
        /// The file's status changed as `change` asked, as the reloaded item confirms.
        case statusChanged(StatusChange)
        /// The server accepted the toggle, but the reload couldn't confirm the direction: it
        /// failed, or the file is gone or shows the other status (another client changed it
        /// first, so the toggle flipped it back). `filename` is the change's.
        case statusUpdated(filename: String)
        /// The send failed. `message` is the server's explanation (``serverMessage(_:)``).
        case sendFailed(deviceName: String, message: String?)
        /// The status change failed. `message` is the server's explanation (``serverMessage(_:)``).
        case statusChangeFailed(message: String?)
        /// Another action was running, or the change is no longer offered; nothing was sent.
        case ignored
    }

    /// The longest server text shown; longer bodies are pages or dumps, not explanations.
    static let maxMessageLength = 200

    public let itemID: String
    /// An action is in flight, a status change until its reload ends; the menu disables the
    /// ebook entries meanwhile.
    public private(set) var isBusy = false
    /// The reload after a status change failed, so the item's files may be stale.
    public private(set) var needsReload = false

    @ObservationIgnored private var service: any EbookActionsService

    public init(itemID: String, service: any EbookActionsService) {
        self.itemID = itemID
        self.service = service
    }

    /// Uses `service` (the account's new client) for later actions. An action in flight finishes
    /// on the old one; ``isBusy`` and ``needsReload`` are kept.
    public func replaceService(_ service: any EbookActionsService) {
        self.service = service
    }

    // MARK: Gating

    /// The devices to offer for Send ebook to device, in the server's order; empty when it isn't
    /// offered.
    public static func devices(authorization: AuthResponse?, item: LibraryItem?, isGone: Bool) -> [EReaderDevice] {
        guard !isGone, item?.book?.ebookFile != nil else { return [] }
        return (authorization?.ereaderDevices ?? []).filter { !$0.name.isEmpty }
    }

    /// The status changes to offer, one per ebook file with an inode, in the item's order; empty
    /// without the update permission or for items that aren't books.
    public static func statusChanges(
        authorization: AuthResponse?, item: LibraryItem?, isGone: Bool
    ) -> [StatusChange] {
        guard !isGone, let user = authorization?.user, user.permissions.update, user.isActive,
            let item, item.book != nil
        else { return [] }
        return (item.libraryFiles ?? []).compactMap { file in
            guard file.fileType == "ebook", !file.ino.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return StatusChange(
                id: file.ino, filename: file.metadata?.filename ?? "", makesPrimary: file.isSupplementary == true)
        }
    }

    /// ``statusChanges(authorization:item:isGone:)`` for this model's item, hidden while
    /// ``needsReload``.
    public func offeredStatusChanges(authorization: AuthResponse?, item: LibraryItem?, isGone: Bool) -> [StatusChange] {
        guard !needsReload, item?.id == itemID else { return [] }
        return Self.statusChanges(authorization: authorization, item: item, isGone: isGone)
    }

    /// The item loaded successfully; its files are current again.
    public func itemDidLoad() {
        needsReload = false
    }

    // MARK: Actions

    /// No action is running and `offered` has `deviceName`; checked before announcing a send.
    public func canSend(to deviceName: String, offered: [EReaderDevice]) -> Bool {
        !isBusy && offered.contains { $0.name == deviceName }
    }

    /// Sends the primary ebook to `deviceName` if `offered` (the devices the menu would offer now,
    /// ``devices(authorization:item:isGone:)``) still has it: the account may have lost its
    /// authorization, or a refresh removed the primary ebook, since the menu opened.
    public func send(to deviceName: String, offered: [EReaderDevice]) async -> Outcome {
        guard canSend(to: deviceName, offered: offered) else { return .ignored }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.sendEbookToDevice(itemID: itemID, deviceName: deviceName)
            return .sent(deviceName: deviceName)
        } catch {
            return .sendFailed(deviceName: deviceName, message: Self.serverMessage(error))
        }
    }

    /// Applies `change` if `offered` (what the menu would offer now) still contains it, then
    /// awaits `reload`, which returns the item it loaded or `nil` if it failed, before the entries
    /// are enabled again. A failed reload sets ``needsReload``.
    ///
    /// The server flips the file's current status, which another client may have changed since
    /// the menu was built, so success is ``Outcome/statusChanged(_:)`` only when the reloaded
    /// item shows the file in the requested state (``confirms(_:in:)``); otherwise it's
    /// ``Outcome/statusUpdated(filename:)``.
    ///
    /// The toggle isn't idempotent, so a failure reloads too unless the server certainly didn't
    /// apply it (``wasRejected(_:)``): after a timeout, a lost connection or a 5xx it may have,
    /// and offering the old direction again would undo it.
    public func apply(
        _ change: StatusChange, offered: [StatusChange], reload: () async -> LibraryItem?
    ) async -> Outcome {
        guard !isBusy, offered.contains(change) else { return .ignored }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.toggleEbookFileStatus(itemID: itemID, fileID: change.id)
        } catch {
            if !Self.wasRejected(error) { needsReload = await reload() == nil }
            return .statusChangeFailed(message: Self.serverMessage(error))
        }
        let reloaded = await reload()
        needsReload = reloaded == nil
        return confirms(change, in: reloaded) ? .statusChanged(change) : .statusUpdated(filename: change.filename)
    }

    /// `item` is this model's item and has the changed file in the state `change` asked for:
    /// supplementary or not, the server's own `isSupplementary` (a missing value is primary, as
    /// in ``statusChanges(authorization:item:isGone:)``).
    func confirms(_ change: StatusChange, in item: LibraryItem?) -> Bool {
        guard let item, item.id == itemID,
            let file = item.libraryFiles?.first(where: { $0.ino == change.id && $0.fileType == "ebook" })
        else { return false }
        return (file.isSupplementary == true) != change.makesPrimary
    }

    /// The request certainly didn't change anything: it never left (no URL, encoding, no
    /// session), or the server answered with a 3xx it wasn't followed through, 401, 403, 404 or
    /// another 4xx. Anything else (timeouts, connection loss, cancellation, 5xx, an unreadable
    /// reply) leaves it unknown.
    static func wasRejected(_ error: any Error) -> Bool {
        switch error as? APIError {
        case .invalidURL, .encoding, .notAuthenticated, .sessionExpired, .redirectRefused, .unauthorized,
            .forbidden, .notFound:
            true
        case .http(let status, _): (400..<500).contains(status)
        case .network, .timedOut, .invalidResponse, .decoding, nil: false
        }
    }

    /// The server's explanation of a failure, worth showing: only a 400's plain text (the
    /// mailer's error, or "Invalid ebook file id"), and not when it looks like markup or is
    /// longer than ``maxMessageLength``. Proxy pages (5xx), 401 and 403 bodies, and 404s (whose
    /// text ``APIError/notFound`` drops) give `nil`, and the view shows its own message.
    static func serverMessage(_ error: any Error) -> String? {
        guard case .http(400, let message?) = error as? APIError,
            !message.contains("<"), message.count <= maxMessageLength
        else { return nil }
        return message
    }
}
