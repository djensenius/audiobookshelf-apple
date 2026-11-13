import ABSAppModel
import ABSCore
import ABSUI
import OSLog
import SwiftUI

/// An EPUB in the epub.js web host (ADR 0008 §1): opens the book at the resume CFI with its cached
/// locations and the reader settings, records each `relocated` page, and turns pages on taps at
/// the sides (a tap in the middle shows or hides the chrome) and with the arrow keys.
struct EPUBReaderView: View {
    let model: ReaderContainerModel
    let fileURL: URL
    let payload: ReaderSettingsPayload
    @State private var session: EPUBReaderSession?

    var body: some View {
        Group {
            if let session, session.failed {
                ErrorStateView(title: L10n.string("MessageReaderLoadFailed"), systemImage: "book")
            } else if let session {
                EPUBWebView(controller: session.controller)
                    .ignoresSafeArea()
                    .background {
                        // Hidden buttons, so the arrow keys turn pages wherever focus is.
                        Group {
                            Button {
                                session.turn(.prev)
                            } label: {
                                EmptyView()
                            }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                            Button {
                                session.turn(.next)
                            } label: {
                                EmptyView()
                            }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                        }
                        .opacity(0)
                        .accessibilityHidden(true)
                    }
            } else {
                // Shown until the session exists: an empty `Group` has no child to run `onAppear`.
                LoadingView()
            }
        }
        .onAppear {
            if session == nil { session = EPUBReaderSession(model: model, fileURL: fileURL, payload: payload) }
        }
        .onChange(of: payload) { _, payload in session?.apply(payload) }
    }
}

/// One opened EPUB: the web view's controller and what the page's events change. The page's event
/// closure holds the session weakly, so the controller doesn't keep it alive.
@MainActor @Observable
final class EPUBReaderSession {
    private(set) var failed = false
    let controller: EPUBReaderController
    @ObservationIgnored private let model: ReaderContainerModel
    @ObservationIgnored private var payload: ReaderSettingsPayload
    @ObservationIgnored private var isOpen = false
    /// Whether the next `relocated` is where the book rendered on opening rather than a turn.
    @ObservationIgnored private var awaitsOpeningLocation = true
    @ObservationIgnored private let locationsKey: EPUBLocationsKey
    private static let bookURL = URL(string: "\(EPUBSchemeHandler.scheme)://book/book.epub")!
    private static let log = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "EPUBReader")

    init(model: ReaderContainerModel, fileURL: URL, payload: ReaderSettingsPayload) {
        self.model = model
        self.payload = payload
        let request = model.request
        // With the file's version, so a file edited in place (same ino) gets new locations, as it
        // gets a new cached copy.
        locationsKey = EPUBLocationsKey(
            connectionID: request.connectionID, itemID: request.itemID,
            ebookFileIno: "\(request.fileIno ?? "")\u{0}\(request.version)")
        controller = EPUBReaderController { _ in try await Self.read(fileURL) }
        controller.onEvent = { [weak self] data in self?.handle(data) }
    }

    func turn(_ command: EPUBBridgeCommand) {
        guard isOpen else { return }
        send(command)
    }

    func apply(_ payload: ReaderSettingsPayload) {
        self.payload = payload
        guard isOpen, let settings = try? EPUBSettingsJSON(encoding: payload) else { return }
        send(.applySettings(settings))
    }

    private func handle(_ data: Data) {
        let event: EPUBBridgeEvent
        do {
            // The table of contents isn't shown yet, so its tree isn't decoded.
            event = try EPUBBridgeEvent.decode(data, skipping: ["toc"])
        } catch {
            Self.log.error("Undecodable reader event: \(String(describing: error), privacy: .public)")
            return
        }
        switch event {
        case .ready:
            Task { await open() }
        case .relocated(let relocation):
            if awaitsOpeningLocation {
                awaitsOpeningLocation = false
                model.recordOpening(.cfi(relocation.startCfi), progress: relocation.progress)
            } else {
                model.record(.cfi(relocation.startCfi), progress: relocation.progress)
            }
        case .locationsReady(let locations):
            let key = locationsKey
            Task { await ReaderCaches.locations.store(locations, for: key) }
        case .tap(let x, _):
            if x < 0.25 {
                turn(.prev)
            } else if x > 0.75 {
                turn(.next)
            } else {
                model.toggleChrome()
            }
        case .error(let message, let phase):
            Self.log.error("Reader \(phase ?? "?", privacy: .public) failed: \(message, privacy: .public)")
            if phase == "open" { failed = true }
        case .toc, .unknown:
            break
        }
    }

    private func open() async {
        guard !isOpen else { return }
        let locations = await ReaderCaches.locations.locations(for: locationsKey)
        let location: String? = if case .cfi(let cfi) = model.resumePoint.location { cfi } else { nil }
        let opening = payload
        do {
            let settings = try EPUBSettingsJSON(encoding: opening)
            try await controller.send(
                EPUBBridgeCommand.open(url: Self.bookURL, location: location, locations: locations, settings: settings)
                    .jsonData())
            isOpen = true
            // Settings changed while the book opened.
            if payload != opening { apply(payload) }
        } catch {
            failed = true
        }
    }

    private func send(_ command: EPUBBridgeCommand) {
        Task {
            do {
                try await controller.send(command.jsonData())
            } catch {
                Self.log.error("Reader command failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Reads the book off the main actor.
    @concurrent private static func read(_ url: URL) async throws -> Data {
        try Data(contentsOf: url, options: .mappedIfSafe)
    }
}
