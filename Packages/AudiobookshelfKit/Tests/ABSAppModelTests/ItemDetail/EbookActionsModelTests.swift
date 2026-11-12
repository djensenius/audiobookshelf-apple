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
        #expect(await model.send(to: "Kindle") == .sent(deviceName: "Kindle"))
        #expect(service.calls == ["send li1 Kindle"])
        #expect(!model.isBusy)
    }

    @Test func sendFailureKeepsShortPlainText400() async {
        let service = FakeEbookActionsService(error: APIError.http(status: 400, message: "Invalid login"))
        let model = EbookActionsModel(itemID: "li1", service: service)
        #expect(await model.send(to: "Kindle") == .sendFailed(deviceName: "Kindle", message: "Invalid login"))
        #expect(!model.isBusy)
    }

    @Test func sendFailureWithoutTextHasNoMessage() async {
        let model = EbookActionsModel(itemID: "li1", service: FakeEbookActionsService(error: APIError.notFound))
        #expect(await model.send(to: "Kindle") == .sendFailed(deviceName: "Kindle", message: nil))
        let offline = EbookActionsModel(
            itemID: "li1", service: FakeEbookActionsService(error: URLError(.notConnectedToInternet)))
        #expect(await offline.send(to: "Kindle") == .sendFailed(deviceName: "Kindle", message: nil))
    }

    @Test func sendFailureHidesHTMLAndForbiddenBodies() async {
        let html = EbookActionsModel(
            itemID: "li1",
            service: FakeEbookActionsService(error: APIError.http(status: 502, message: "<html>Bad Gateway</html>")))
        #expect(await html.send(to: "K") == .sendFailed(deviceName: "K", message: nil))
        let forbidden = EbookActionsModel(
            itemID: "li1", service: FakeEbookActionsService(error: APIError.forbidden(message: "Forbidden")))
        #expect(await forbidden.send(to: "K") == .sendFailed(deviceName: "K", message: nil))
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
            return true
        }
        #expect(outcome == .statusChanged(makeB))
        #expect(callsAtReload == ["toggle li1 b"])
        #expect(busyDuringReload == true)
        #expect(!model.isBusy)
        #expect(!model.needsReload)
    }

    @Test func failedReloadHidesChangesUntilTheItemLoads() async {
        let model = EbookActionsModel(itemID: "li1", service: FakeEbookActionsService())
        #expect(await model.apply(makeB, offered: [makeB]) { false } == .statusChanged(makeB))
        #expect(model.needsReload)
        #expect(model.offeredStatusChanges(authorization: auth(update: true), item: twoFiles, isGone: false).isEmpty)
        model.itemDidLoad()
        #expect(model.offeredStatusChanges(authorization: auth(update: true), item: twoFiles, isGone: false).count == 2)
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
                return true
            } == .ignored)
        #expect(
            await model.apply(makeB, offered: []) {
                reloads += 1
                return true
            } == .ignored)
        #expect(service.calls.isEmpty)
        #expect(reloads == 0)
    }

    @Test func applyFailureDoesNotReload() async {
        let service = FakeEbookActionsService(error: APIError.forbidden(message: "Forbidden"))
        let model = EbookActionsModel(itemID: "li1", service: service)
        var reloads = 0
        let outcome = await model.apply(makeB, offered: [makeB]) {
            reloads += 1
            return true
        }
        #expect(outcome == .statusChangeFailed(message: nil))
        #expect(reloads == 0)
        #expect(!model.needsReload)
    }

    // MARK: Busy

    @Test func oneActionAtATime() async {
        let service = FakeEbookActionsService(holdsFirstCall: true)
        let model = EbookActionsModel(itemID: "li1", service: service)
        let first = Task { await model.send(to: "Kindle") }
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
        #expect(await model.apply(makeB, offered: [makeB]) { true } == .ignored)
        #expect(await model.send(to: "Kobo") == .ignored)
        service.release()
        #expect(await first.value == .sent(deviceName: "Kindle"))
        #expect(!model.isBusy)
        #expect(service.calls == ["send li1 Kindle"])
    }
}
