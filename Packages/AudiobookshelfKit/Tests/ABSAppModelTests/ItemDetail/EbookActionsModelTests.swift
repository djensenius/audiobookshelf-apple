import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// Records calls and fails with `error` when it's set.
private final class FakeEbookActionsService: EbookActionsService, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    let error: (any Error)?
    /// Suspends each call until released, to test the busy state.
    let gate: AsyncStream<Void>?

    init(error: (any Error)? = nil, gate: AsyncStream<Void>? = nil) {
        self.error = error
        self.gate = gate
    }

    var calls: [String] { lock.withLock { _calls } }

    func sendEbookToDevice(itemID: String, deviceName: String) async throws {
        try await record("send \(itemID) \(deviceName)")
    }

    func toggleEbookFileStatus(itemID: String, fileID: String) async throws {
        try await record("toggle \(itemID) \(fileID)")
    }

    private func record(_ call: String) async throws {
        lock.withLock { _calls.append(call) }
        if let gate { for await _ in gate { break } }
        if let error { throw error }
    }
}

private func row(_ id: String, isPrimary: Bool) -> ItemDetailModel.EbookFileRow {
    ItemDetailModel.EbookFileRow(id: id, filename: "\(id).epub", format: .epub, size: nil, isPrimary: isPrimary)
}

private func auth(
    update: Bool = false, isActive: Bool = true, devices: [EReaderDevice]? = [EReaderDevice(name: "Kindle")]
) -> AuthResponse {
    AuthResponse(
        user: User(id: "u1", username: "reader", isActive: isActive, permissions: UserPermissions(update: update)),
        ereaderDevices: devices)
}

@MainActor
@Suite struct EbookActionsModelTests {
    // MARK: Send to device gating

    @Test func devicesOfferedWithPrimaryEbook() {
        let devices = EbookActionsModel.devices(
            authorization: auth(devices: [EReaderDevice(name: "Kindle"), EReaderDevice(name: "Kobo")]),
            ebookFiles: [row("a", isPrimary: true)], isGone: false)
        #expect(devices.map(\.name) == ["Kindle", "Kobo"])
    }

    @Test(arguments: [nil, [EReaderDevice]()])
    func noDevicesHidesSend(devices: [EReaderDevice]?) {
        #expect(
            EbookActionsModel.devices(
                authorization: auth(devices: devices), ebookFiles: [row("a", isPrimary: true)], isGone: false
            ).isEmpty)
    }

    @Test func onlySupplementaryEbooksHidesSend() {
        // The server sends `media.ebookFile` only.
        #expect(
            EbookActionsModel.devices(
                authorization: auth(), ebookFiles: [row("a", isPrimary: false)], isGone: false
            ).isEmpty)
        #expect(EbookActionsModel.devices(authorization: auth(), ebookFiles: [], isGone: false).isEmpty)
    }

    @Test func signedOutOrGoneHidesSend() {
        let files = [row("a", isPrimary: true)]
        #expect(EbookActionsModel.devices(authorization: nil, ebookFiles: files, isGone: false).isEmpty)
        #expect(EbookActionsModel.devices(authorization: auth(), ebookFiles: files, isGone: true).isEmpty)
    }

    @Test func blankDeviceNamesAreSkipped() {
        let devices = EbookActionsModel.devices(
            authorization: auth(devices: [EReaderDevice(name: ""), EReaderDevice(name: "Kobo")]),
            ebookFiles: [row("a", isPrimary: true)], isGone: false)
        #expect(devices.map(\.name) == ["Kobo"])
    }

    // MARK: Status gating

    @Test func statusChangesNeedUpdatePermission() {
        let files = [row("a", isPrimary: true), row("b", isPrimary: false)]
        let changes = EbookActionsModel.statusChanges(
            authorization: auth(update: true), ebookFiles: files, isGone: false)
        #expect(changes.map(\.id) == ["a", "b"])
        #expect(changes.map(\.makesPrimary) == [false, true])
        #expect(changes.map(\.titleKey) == ["LabelSetEbookAsSupplementary", "LabelSetEbookAsPrimary"])
        #expect(changes.map(\.filename) == ["a.epub", "b.epub"])
    }

    /// Negative control: without update permission, inactive, signed out or gone, nothing.
    @Test func statusChangesHiddenWithoutPermission() {
        let files = [row("a", isPrimary: true), row("b", isPrimary: false)]
        #expect(EbookActionsModel.statusChanges(authorization: auth(), ebookFiles: files, isGone: false).isEmpty)
        #expect(
            EbookActionsModel.statusChanges(
                authorization: auth(update: true, isActive: false), ebookFiles: files, isGone: false
            ).isEmpty)
        #expect(EbookActionsModel.statusChanges(authorization: nil, ebookFiles: files, isGone: false).isEmpty)
        #expect(
            EbookActionsModel.statusChanges(authorization: auth(update: true), ebookFiles: files, isGone: true)
                .isEmpty)
    }

    // MARK: Actions

    @Test func sendSucceeds() async {
        let service = FakeEbookActionsService()
        let model = EbookActionsModel(itemID: "li1", service: service)
        #expect(await model.send(to: "Kindle") == .sent(deviceName: "Kindle"))
        #expect(service.calls == ["send li1 Kindle"])
        #expect(!model.isBusy)
    }

    @Test func sendFailureKeepsServerText() async {
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

    @Test func applyTogglesStatus() async {
        let service = FakeEbookActionsService()
        let model = EbookActionsModel(itemID: "li1", service: service)
        let change = EbookActionsModel.StatusChange(id: "42", filename: "b.epub", makesPrimary: true)
        #expect(await model.apply(change) == .statusChanged(change))
        #expect(service.calls == ["toggle li1 42"])
    }

    @Test func applyFailureKeepsForbiddenText() async {
        let service = FakeEbookActionsService(error: APIError.forbidden(message: "Forbidden"))
        let model = EbookActionsModel(itemID: "li1", service: service)
        let change = EbookActionsModel.StatusChange(id: "42", filename: "b.epub", makesPrimary: false)
        #expect(await model.apply(change) == .statusChangeFailed(message: "Forbidden"))
    }

    @Test func oneActionAtATime() async {
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        let service = FakeEbookActionsService(gate: gate)
        let model = EbookActionsModel(itemID: "li1", service: service)
        let first = Task { await model.send(to: "Kindle") }
        while !model.isBusy { await Task.yield() }
        let change = EbookActionsModel.StatusChange(id: "42", filename: "b.epub", makesPrimary: true)
        #expect(await model.apply(change) == .ignored)
        #expect(await model.send(to: "Kobo") == .ignored)
        release.yield()
        #expect(await first.value == .sent(deviceName: "Kindle"))
        #expect(!model.isBusy)
        #expect(service.calls == ["send li1 Kindle"])
    }
}
