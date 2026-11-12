import ABSAPI
import ABSAppModel
import ABSCore
import ABSData
import Foundation
import Observation

/// The app's long-lived objects. One instance is shared by every window scene and CarPlay, so
/// nothing here belongs to a view (ADR 0001 and 0004).
///
/// The shell takes what it needs from here: the root view follows ``lifecycle``'s gate, and the
/// CarPlay delegate starts ``lifecycle`` without a window. The next steps of #44 add the
/// library, playback and downloads. Each registers with ``lifecycle`` as a session
/// participant before ``SessionLifecycle/start()``, so build them here, in `init`.
@MainActor
final class AppEnvironment {
    /// Built on first use, so a process that never asks for it opens no store. A Debug build
    /// launched with `-ABSFixtures` gets ``FixtureServer``'s in-memory environment instead.
    static let shared: AppEnvironment = {
        #if DEBUG
            if FixtureServer.isEnabled { return FixtureServer.environment() }
        #endif
        return AppEnvironment()
    }()

    let settings: AppSettings
    /// The on-device store, or `nil` when it couldn't be opened. ``lifecycle`` then shows
    /// ``AuthGate/storeUnavailable(_:)``, because nothing can be restored or saved.
    let dataStack: DataStack?
    let accounts: AccountManager?
    let lifecycle: SessionLifecycle
    /// The stable device ID for playback sessions (ADR 0007), kept in the same Keychain as the
    /// accounts. It doesn't need the store, so it exists even when ``dataStack`` is `nil`.
    let deviceIdentifiers: any DeviceIdentifying
    let player: any PlayerSlotState
    /// The shared library and its session participant (#181), or `nil` without ``accounts``.
    let library: LibraryParticipant?
    /// The cover image pipeline and its session participant (#182).
    let images: ImageServices

    /// - Parameters:
    ///   - settings: The settings every scene shares.
    ///   - storeLocation: Where the store lives; tests and previews pass `.inMemory`.
    ///   - covers: Where the cover pipeline fetches and caches covers.
    init(
        settings: AppSettings = AppSettings(), storeLocation: DataStack.Location = .appGroup,
        keychain: any KeychainStoring = KeychainStore(),
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .absConnection() },
        covers: CoverSource = .app
    ) {
        let dataStack: DataStack?
        let accounts: AccountManager?
        let lifecycle: SessionLifecycle
        do {
            let stack = try DataStack(location: storeLocation)
            let manager = AccountManager(
                store: ServerConnectionStore(modelContainer: stack.container), keychain: keychain,
                validator: ServerValidator(sessionConfiguration: sessionConfiguration),
                openID: OIDCLoginService(sessionConfiguration: sessionConfiguration),
                sessionConfiguration: sessionConfiguration, settings: settings)
            dataStack = stack
            accounts = manager
            lifecycle = SessionLifecycle(source: AccountSessionAdapter(accounts: manager))
        } catch {
            let reason = Log.redact(String(describing: error))
            Log.data.fault("The on-device store couldn't be opened: \(reason, privacy: .public)")
            dataStack = nil
            accounts = nil
            lifecycle = SessionLifecycle(storeUnavailable: error)
        }
        self.settings = settings
        self.dataStack = dataStack
        self.accounts = accounts
        self.lifecycle = lifecycle
        self.deviceIdentifiers = DeviceIdentifierStore(keychain: keychain)
        // Replaced by the playback coordinator's view model with the player UI (#56).
        self.player = PlaceholderPlayerState()
        self.library = accounts.map { Self.makeLibrary(settings: settings, accounts: $0, lifecycle: lifecycle) }

        // Images (#182).
        let images = ImageServices(
            accounts: accounts, sweepsRemovedConnections: dataStack?.resolvedLocation == .appGroup, covers: covers)
        lifecycle.register(images.participant, stage: .connect)
        self.images = images
    }
}

private struct NoSuchConnection: Error {}

/// A preview account source with nobody signed in, so the gate settles on ``AuthGate/connect``.
@MainActor @Observable
final class SignedOutAccountSource: AccountSessionSource {
    let phase = AccountSessionPhase.signedOut
    let client: APIClient? = nil

    func restore() async throws {}
    func logout() async -> URL? { nil }
    func `switch`(to connectionID: UUID) async throws { throw NoSuchConnection() }
    func remove(_ connectionID: UUID) async throws -> URL? { throw NoSuchConnection() }
}
