import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// Records calls and fails with `error` when it's set. The first call can be held until
/// `release()`; later calls return at once.
///
/// `@unchecked Sendable`: every mutable property is read and written under `lock`, and the held
/// continuation is taken out under the lock, so it's resumed exactly once.
private final class FakeEbookActionsService: EbookActionsService, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var holdsFirstCall: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    let error: (any Error)?

    init(error: (any Error)? = nil, holdsFirstCall: Bool = false) {
        self.error = error
        self.holdsFirstCall = holdsFirstCall
    }

    var calls: [String] { lock.withLock { _calls } }

    func release() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }

    func sendEbookToDevice(itemID: String, deviceName: String) async throws {
        try await record("send \(itemID) \(deviceName)")
    }

    func toggleEbookFileStatus(itemID: String, fileID: String) async throws {
        try await record("toggle \(itemID) \(fileID)")
    }

    private func record(_ call: String) async throws {
        let holds = lock.withLock {
            _calls.append(call)
            defer { holdsFirstCall = false }
            return holdsFirstCall
        }
        if holds {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock {
                    if released { return true }
                    held = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        if let error { throw error }
    }
}

private func ebook(_ ino: String, supplementary: Bool?) -> LibraryFile {
    LibraryFile(
        ino: ino, metadata: FileMetadata(filename: "\(ino).epub", ext: ".epub", path: "/b/\(ino).epub"),
        isSupplementary: supplementary, fileType: "ebook")
}

private func item(
    id: String = "li1", primary: String? = nil, files: [LibraryFile] = [], isBook: Bool = true
) -> LibraryItem {
    let book = Book(
        id: "b-\(id)", libraryItemId: id, metadata: BookMetadata(title: "Book"),
        ebookFile: primary.map { EbookFile(ino: $0) })
    let media: LibraryItemMedia =
        isBook ? .book(book) : .podcast(Podcast(id: "pod", metadata: PodcastMetadata(title: "Show")))
    return LibraryItem(
        id: id, libraryId: "lib", mediaType: isBook ? .book : .podcast, media: media, libraryFiles: files)
}

private func auth(
    update: Bool = false, isActive: Bool = true, devices: [EReaderDevice]? = [EReaderDevice(name: "Kindle")]
) -> AuthResponse {
    AuthResponse(
        user: User(id: "u1", username: "reader", isActive: isActive, permissions: UserPermissions(update: update)),
        ereaderDevices: devices)
}

private let twoFiles = item(primary: "a", files: [ebook("a", supplementary: false), ebook("b", supplementary: true)])
private let makeB = EbookActionsModel.StatusChange(id: "b", filename: "b.epub", makesPrimary: true)
/// ``twoFiles`` after ``makeB``: b is primary, a supplementary.
private let afterB = item(primary: "b", files: [ebook("a", supplementary: true), ebook("b", supplementary: false)])
/// The devices the menu offers when tapped.
private let offered = ["Kindle", "Kobo", "K"].map { EReaderDevice(name: $0) }

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EbookActionsModelTests {
    // MARK: Send to device gating

    @Test func devicesOfferedWithPrimaryEbook() {
        let devices = EbookActionsModel.devices(
            authorization: auth(devices: [EReaderDevice(name: "Kindle"), EReaderDevice(name: "Kobo")]),
            item: twoFiles, isGone: false)
        #expect(devices.map(\.name) == ["Kindle", "Kobo"])
    }

    @Test(arguments: [nil, [EReaderDevice]()])
    func noDevicesHidesSend(devices: [EReaderDevice]?) {
        #expect(EbookActionsModel.devices(authorization: auth(devices: devices), item: twoFiles, isGone: false).isEmpty)
    }

    @Test func noPrimaryEbookHidesSend() {
        // The server sends `media.ebookFile` only.
        let supplementaryOnly = item(files: [ebook("a", supplementary: true)])
        #expect(EbookActionsModel.devices(authorization: auth(), item: supplementaryOnly, isGone: false).isEmpty)
        #expect(EbookActionsModel.devices(authorization: auth(), item: nil, isGone: false).isEmpty)
    }

    @Test func signedOutOrGoneHidesSend() {
        #expect(EbookActionsModel.devices(authorization: nil, item: twoFiles, isGone: false).isEmpty)
        #expect(EbookActionsModel.devices(authorization: auth(), item: twoFiles, isGone: true).isEmpty)
    }

    @Test func blankDeviceNamesAreSkipped() {
        let devices = EbookActionsModel.devices(
            authorization: auth(devices: [EReaderDevice(name: ""), EReaderDevice(name: "Kobo")]), item: twoFiles,
            isGone: false)
        #expect(devices.map(\.name) == ["Kobo"])
    }

    // MARK: Status gating

    @Test func statusChangesFollowEachFilesOwnStatus() {
        let changes = EbookActionsModel.statusChanges(authorization: auth(update: true), item: twoFiles, isGone: false)
        #expect(changes.map(\.id) == ["a", "b"])
        #expect(changes.map(\.makesPrimary) == [false, true])
        #expect(changes.map(\.titleKey) == ["LabelSetEbookAsSupplementary", "LabelSetEbookAsPrimary"])
        #expect(changes.map(\.filename) == ["a.epub", "b.epub"])
    }

    /// Legacy data: `media.ebookFile` is null while a file isn't supplementary. The server flips
    /// the file's own flag, so the change offered for it is Set as supplementary.
    @Test func directionComesFromIsSupplementaryNotEbookFile() {
        let legacy = item(primary: nil, files: [ebook("a", supplementary: nil), ebook("b", supplementary: true)])
        let changes = EbookActionsModel.statusChanges(authorization: auth(update: true), item: legacy, isGone: false)
        #expect(changes.map(\.makesPrimary) == [false, true])
    }

    /// A legacy server's item with `media.ebookFile.ino: null` decodes, and its ebooks still get
    /// their status changes (from each file's `isSupplementary`) and send to device.
    @Test func legacyNullEbookInodeDecodesAndReachesStatusActions() async throws {
        let json = """
            {"id":"li1","libraryId":"lib","mediaType":"book","media":{"id":"b1","libraryItemId":"li1",\
            "metadata":{"title":"Book"},"ebookFile":{"ino":null,"metadata":{"filename":"a.epub","ext":".epub",\
            "path":"/b/a.epub"},"ebookFormat":"epub"}},"libraryFiles":[\
            {"ino":"a","metadata":{"filename":"a.epub","ext":".epub","path":"/b/a.epub"},"isSupplementary":null,\
            "fileType":"ebook"},\
            {"ino":"b","metadata":{"filename":"b.epub","ext":".epub","path":"/b/b.epub"},"isSupplementary":true,\
            "fileType":"ebook"}]}
            """
        let legacy = try JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8))
        #expect(legacy.book?.ebookFile?.ino == "")
        #expect(legacy.book?.ebookFile?.ebookFormat == .epub)
        #expect(EbookActionsModel.devices(authorization: auth(), item: legacy, isGone: false).map(\.name) == ["Kindle"])

        let changes = EbookActionsModel.statusChanges(authorization: auth(update: true), item: legacy, isGone: false)
        #expect(changes.map(\.id) == ["a", "b"])
        #expect(changes.map(\.makesPrimary) == [false, true])
        let service = FakeEbookActionsService()
        let model = EbookActionsModel(itemID: "li1", service: service)
        let offered = model.offeredStatusChanges(authorization: auth(update: true), item: legacy, isGone: false)
        let reloaded = item(id: legacy.id, files: [ebook("a", supplementary: nil), ebook("b", supplementary: false)])
        #expect(await model.apply(changes[1], offered: offered) { reloaded } == .statusChanged(changes[1]))
        #expect(service.calls == ["toggle li1 b"])
    }

    @Test func filesWithoutInodeOrNotEbooksAreSkipped() {
        let files = [
            ebook("", supplementary: true), ebook("  ", supplementary: true), ebook("a", supplementary: false),
            LibraryFile(ino: "au", fileType: "audio"),
        ]
        let changes = EbookActionsModel.statusChanges(
            authorization: auth(update: true), item: item(primary: "a", files: files), isGone: false)
        #expect(changes.map(\.id) == ["a"])
    }

    /// Negative control: without update permission, inactive, signed out, gone or not a book,
    /// nothing.
    @Test func statusChangesHiddenWithoutPermission() {
        #expect(EbookActionsModel.statusChanges(authorization: auth(), item: twoFiles, isGone: false).isEmpty)
        #expect(
            EbookActionsModel.statusChanges(
                authorization: auth(update: true, isActive: false), item: twoFiles, isGone: false
            ).isEmpty)
        #expect(EbookActionsModel.statusChanges(authorization: nil, item: twoFiles, isGone: false).isEmpty)
        #expect(
            EbookActionsModel.statusChanges(authorization: auth(update: true), item: twoFiles, isGone: true).isEmpty)
        let podcast = item(files: [ebook("a", supplementary: true)], isBook: false)
        #expect(
            EbookActionsModel.statusChanges(authorization: auth(update: true), item: podcast, isGone: false).isEmpty)
    }

    @Test func offeredChangesAreForThisItemOnly() {
        let model = EbookActionsModel(itemID: "other", service: FakeEbookActionsService())
        #expect(model.offeredStatusChanges(authorization: auth(update: true), item: twoFiles, isGone: false).isEmpty)
    }

    // MARK: Send

    @Test func sendSucceeds() async {
        let service = FakeEbookActionsService()
        let model = EbookActionsModel(itemID: "li1", service: service)
        #expect(await model.send(to: "Kindle", offered: offered) == .sent(deviceName: "Kindle"))
        #expect(service.calls == ["send li1 Kindle"])
        #expect(!model.isBusy)
    }

    /// The tap is checked against what would be offered now: nothing is sent once the account
    /// lost its devices or authorization, or the item its primary ebook.
    @Test func sendNoLongerOfferedIsIgnored() async {
        let service = FakeEbookActionsService()
        let model = EbookActionsModel(itemID: "li1", service: service)
        let noPrimary = item(primary: nil, files: [ebook("b", supplementary: true)])
        for now in [
            EbookActionsModel.devices(authorization: nil, item: twoFiles, isGone: false),
            EbookActionsModel.devices(authorization: auth(), item: noPrimary, isGone: false),
            EbookActionsModel.devices(authorization: auth(), item: twoFiles, isGone: true),
            EbookActionsModel.devices(
                authorization: auth(devices: [EReaderDevice(name: "Kobo")]), item: twoFiles, isGone: false),
        ] {
            #expect(!model.canSend(to: "Kindle", offered: now))
            #expect(await model.send(to: "Kindle", offered: now) == .ignored)
        }
        #expect(service.calls.isEmpty)
        let current = EbookActionsModel.devices(authorization: auth(), item: twoFiles, isGone: false)
        #expect(model.canSend(to: "Kindle", offered: current))
    }

    @Test func sendFailureKeepsShortPlainText400() async {
        let service = FakeEbookActionsService(error: APIError.http(status: 400, message: "Invalid login"))
        let model = EbookActionsModel(itemID: "li1", service: service)
        #expect(
            await model.send(to: "Kindle", offered: offered)
                == .sendFailed(deviceName: "Kindle", message: "Invalid login"))
        #expect(!model.isBusy)
    }

    @Test func sendFailureWithoutTextHasNoMessage() async {
        let model = EbookActionsModel(itemID: "li1", service: FakeEbookActionsService(error: APIError.notFound))
        #expect(await model.send(to: "Kindle", offered: offered) == .sendFailed(deviceName: "Kindle", message: nil))
        let offline = EbookActionsModel(
            itemID: "li1", service: FakeEbookActionsService(error: URLError(.notConnectedToInternet)))
        #expect(await offline.send(to: "Kindle", offered: offered) == .sendFailed(deviceName: "Kindle", message: nil))
    }

    @Test func sendFailureHidesHTMLAndForbiddenBodies() async {
        let html = EbookActionsModel(
            itemID: "li1",
            service: FakeEbookActionsService(error: APIError.http(status: 502, message: "<html>Bad Gateway</html>")))
        #expect(await html.send(to: "K", offered: offered) == .sendFailed(deviceName: "K", message: nil))
        let forbidden = EbookActionsModel(
            itemID: "li1", service: FakeEbookActionsService(error: APIError.forbidden(message: "Forbidden")))
        #expect(await forbidden.send(to: "K", offered: offered) == .sendFailed(deviceName: "K", message: nil))
    }

    // MARK: Server messages

    @Test(arguments: [
        APIError.http(status: 502, message: "<html><body><h1>502 Bad Gateway</h1></body></html>"),
        APIError.http(status: 500, message: "Internal error"),
        APIError.http(status: 400, message: "<p>Bad request</p>"),
        APIError.http(status: 400, message: String(repeating: "x", count: 201)),
        APIError.http(status: 400, message: nil),
        APIError.forbidden(message: "Forbidden"),
        APIError.unauthorized(message: "Unauthorized"),
        APIError.notFound,
    ])
    func serverMessageIsDropped(error: APIError) {
        #expect(EbookActionsModel.serverMessage(error) == nil)
    }

    @Test func serverMessageKeepsShortPlain400() {
        let text = String(repeating: "x", count: 200)
        #expect(EbookActionsModel.serverMessage(APIError.http(status: 400, message: text)) == text)
        #expect(EbookActionsModel.serverMessage(URLError(.timedOut)) == nil)
    }

    // MARK: Status change

    @Test func applyTogglesThenReloadsWhileBusy() async {
        let service = FakeEbookActionsService()
        let model = EbookActionsModel(itemID: "li1", service: service)
        var busyDuringReload: Bool?
        var callsAtReload: [String] = []
        let outcome = await model.apply(makeB, offered: [makeB]) {
            busyDuringReload = model.isBusy
            callsAtReload = service.calls
            return afterB
        }
        #expect(outcome == .statusChanged(makeB))
        #expect(callsAtReload == ["toggle li1 b"])
        #expect(busyDuringReload == true)
        #expect(!model.isBusy)
        #expect(!model.needsReload)
    }

    /// The server flips the file's current status. If another client made b primary after the
    /// menu was built, the toggle makes it supplementary again: the reload shows that, so the
    /// outcome doesn't claim b is now primary. Nor does a reload of another item, or one without
    /// the file.
    @Test func unconfirmedChangeIsNotDirectional() async {
        let flippedBack = twoFiles
        let otherItem = item(id: "li2", primary: "b", files: [ebook("b", supplementary: false)])
        let fileGone = item(primary: "a", files: [ebook("a", supplementary: false)])
        for reloaded in [flippedBack, otherItem, fileGone] {
            let model = EbookActionsModel(itemID: "li1", service: FakeEbookActionsService())
            #expect(await model.apply(makeB, offered: [makeB]) { reloaded } == .statusUpdated(filename: "b.epub"))
            #expect(!model.needsReload)
        }
        // Negative control: the confirming reload gives the directional outcome, both ways.
        let model = EbookActionsModel(itemID: "li1", service: FakeEbookActionsService())
        #expect(await model.apply(makeB, offered: [makeB]) { afterB } == .statusChanged(makeB))
        let makeBSupplementary = EbookActionsModel.StatusChange(id: "b", filename: "b.epub", makesPrimary: false)
        #expect(
            await model.apply(makeBSupplementary, offered: [makeBSupplementary]) { twoFiles }
                == .statusChanged(makeBSupplementary))
    }

    @Test func failedReloadHidesChangesUntilTheItemLoads() async {
        let model = EbookActionsModel(itemID: "li1", service: FakeEbookActionsService())
        #expect(await model.apply(makeB, offered: [makeB]) { nil } == .statusUpdated(filename: "b.epub"))
        #expect(model.needsReload)
        #expect(model.offeredStatusChanges(authorization: auth(update: true), item: twoFiles, isGone: false).isEmpty)
        model.itemDidLoad()
        #expect(model.offeredStatusChanges(authorization: auth(update: true), item: twoFiles, isGone: false).count == 2)
    }

    /// The server sends its current primary ebook, which a toggle whose reload failed may have
    /// changed, so sending waits for the item to load again.
    @Test func failedReloadHidesAndRefusesSendUntilTheItemLoads() async {
        let service = FakeEbookActionsService()
        let model = EbookActionsModel(itemID: "li1", service: service)
        #expect(await model.apply(makeB, offered: [makeB]) { nil } == .statusUpdated(filename: "b.epub"))
        #expect(model.needsReload)
        #expect(model.offeredDevices(authorization: auth(), item: twoFiles, isGone: false).isEmpty)
        // A pending tap carries the devices offered before the change.
        let stale = EbookActionsModel.devices(authorization: auth(), item: twoFiles, isGone: false)
        #expect(!model.canSend(to: "Kindle", offered: stale))
        #expect(await model.send(to: "Kindle", offered: stale) == .ignored)
        #expect(service.calls == ["toggle li1 b"])

        model.itemDidLoad()
        let offered = model.offeredDevices(authorization: auth(), item: twoFiles, isGone: false)
        #expect(offered.map(\.name) == ["Kindle"])
        #expect(await model.send(to: "Kindle", offered: offered) == .sent(deviceName: "Kindle"))
    }

    @Test func offeredDevicesAreForThisItemOnly() {
        let model = EbookActionsModel(itemID: "other", service: FakeEbookActionsService())
        #expect(model.offeredDevices(authorization: auth(), item: twoFiles, isGone: false).isEmpty)
    }

    @Test func staleTapIsDropped() async {
        let service = FakeEbookActionsService()
        let model = EbookActionsModel(itemID: "li1", service: service)
        // The menu said "Set b as primary", but b is primary now, so the offer is the opposite.
        let now = EbookActionsModel.StatusChange(id: "b", filename: "b.epub", makesPrimary: false)
        var reloads = 0
        #expect(
            await model.apply(makeB, offered: [now]) {
                reloads += 1
                return afterB
            } == .ignored)
        #expect(
            await model.apply(makeB, offered: []) {
                reloads += 1
                return afterB
            } == .ignored)
        #expect(service.calls.isEmpty)
        #expect(reloads == 0)
    }

    /// The server refused it, so nothing changed: no reload, and the same entries stay offered.
    @Test(arguments: [
        APIError.forbidden(message: "Forbidden"), .unauthorized(message: nil), .notFound,
        .http(status: 400, message: "Invalid ebook file id"), .notAuthenticated,
    ])
    func rejectedChangeDoesNotReload(error: APIError) async {
        let model = EbookActionsModel(itemID: "li1", service: FakeEbookActionsService(error: error))
        var reloads = 0
        let outcome = await model.apply(makeB, offered: [makeB]) {
            reloads += 1
            return afterB
        }
        #expect(outcome == .statusChangeFailed(message: EbookActionsModel.serverMessage(error)))
        #expect(reloads == 0)
        #expect(!model.needsReload)
    }

    /// The server may have flipped the file before the reply was lost: reload while busy, and hide
    /// the entries if that reload fails, as after a success.
    @Test(arguments: [
        APIError.timedOut, .network(.networkConnectionLost), .http(status: 502, message: nil),
        .invalidResponse, .decoding("empty"),
    ])
    func ambiguousFailureReloadsWhileBusy(error: APIError) async {
        let model = EbookActionsModel(itemID: "li1", service: FakeEbookActionsService(error: error))
        var busyDuringReload: Bool?
        let outcome = await model.apply(makeB, offered: [makeB]) {
            busyDuringReload = model.isBusy
            return nil
        }
        #expect(outcome == .statusChangeFailed(message: nil))
        #expect(busyDuringReload == true)
        #expect(model.needsReload)
        #expect(model.offeredStatusChanges(authorization: auth(update: true), item: twoFiles, isGone: false).isEmpty)
    }

    @Test func cancellationIsAmbiguous() async {
        let model = EbookActionsModel(itemID: "li1", service: FakeEbookActionsService(error: CancellationError()))
        var reloads = 0
        _ = await model.apply(makeB, offered: [makeB]) {
            reloads += 1
            return afterB
        }
        #expect(reloads == 1)
        #expect(!model.needsReload)
    }

    // MARK: Reconnect

    /// A reconnect gives the model the new client; a pending reload and an action in flight are
    /// kept, so nothing stale is offered and nothing overlaps.
    @Test func replacingTheServiceKeepsState() async {
        // A change whose reload failed stays hidden across the reconnect.
        let first = FakeEbookActionsService()
        let model = EbookActionsModel(itemID: "li1", service: first)
        #expect(await model.apply(makeB, offered: [makeB]) { nil } == .statusUpdated(filename: "b.epub"))
        let second = FakeEbookActionsService(holdsFirstCall: true)
        model.replaceService(second)
        #expect(model.needsReload)
        #expect(model.offeredStatusChanges(authorization: auth(update: true), item: twoFiles, isGone: false).isEmpty)
        #expect(await model.send(to: "Kindle", offered: offered) == .ignored)
        model.itemDidLoad()

        // An action in flight on the old client still blocks one on the new client.
        let sending = Task { await model.send(to: "Kindle", offered: offered) }
        var yields = 0
        while !model.isBusy, yields < 1_000 {
            await Task.yield()
            yields += 1
        }
        guard model.isBusy else {
            Issue.record("The send never started.")
            second.release()
            _ = await sending.value
            return
        }
        let third = FakeEbookActionsService()
        model.replaceService(third)
        #expect(model.isBusy)
        #expect(await model.send(to: "Kobo", offered: offered) == .ignored)
        second.release()
        #expect(await sending.value == .sent(deviceName: "Kindle"))

        #expect(await model.send(to: "Kobo", offered: offered) == .sent(deviceName: "Kobo"))
        #expect(first.calls == ["toggle li1 b"])
        #expect(second.calls == ["send li1 Kindle"])
        #expect(third.calls == ["send li1 Kobo"])
    }

    // MARK: Busy

    @Test func oneActionAtATime() async {
        let service = FakeEbookActionsService(holdsFirstCall: true)
        let model = EbookActionsModel(itemID: "li1", service: service)
        let first = Task { await model.send(to: "Kindle", offered: offered) }
        var yields = 0
        while !model.isBusy, yields < 1_000 {
            await Task.yield()
            yields += 1
        }
        guard model.isBusy else {
            Issue.record("The first send never started.")
            service.release()
            _ = await first.value
            return
        }
        #expect(await model.apply(makeB, offered: [makeB]) { afterB } == .ignored)
        #expect(await model.send(to: "Kobo", offered: offered) == .ignored)
        service.release()
        #expect(await first.value == .sent(deviceName: "Kindle"))
        #expect(!model.isBusy)
        #expect(service.calls == ["send li1 Kindle"])
    }
}
