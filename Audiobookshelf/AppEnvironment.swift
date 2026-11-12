import ABSAPI
import ABSAppModel
import ABSCore
import ABSData
import ABSDownloads
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
    /// Built on first use, so a process that never asks for it opens no store.
    static let shared = AppEnvironment()

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
    /// The download stack, or `nil` when the store couldn't be opened. Its lifecycle is
    /// launched here, so a launch without a window (CarPlay, a background wake) has an engine.
    let downloads: AppDownloads?

    /// - Parameters:
    ///   - settings: The settings every scene shares.
    ///   - storeLocation: Where the store lives; tests and previews pass `.inMemory`.
    ///   - downloadsRoot: Where downloads live (``AppDownloads/make(dataStack:accounts:settings:root:makeSession:)``);
    ///     tests pass a temporary directory.
    ///   - makeDownloadSession: The download engine's session; tests pass a non-background one.
    init(
        settings: AppSettings = AppSettings(), storeLocation: DataStack.Location = .appGroup,
        keychain: any KeychainStoring = KeychainStore(),
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .absConnection() },
        downloadsRoot: URL = .applicationSupportDirectory,
        makeDownloadSession: @escaping DownloadSessionFactory = DownloadEngine.backgroundSession()
    ) {
        let dataStack: DataStack?
        let accounts: AccountManager?
        let lifecycle: SessionLifecycle
        var downloads: AppDownloads?
        do {
            let stack = try DataStack(location: storeLocation)
            let manager = AccountManager(
                store: ServerConnectionStore(modelContainer: stack.container), keychain: keychain,
                validator: ServerValidator(sessionConfiguration: sessionConfiguration),
                openID: OIDCLoginService(sessionConfiguration: sessionConfiguration),
                sessionConfiguration: sessionConfiguration)
            let built = AppDownloads.make(
                dataStack: stack, accounts: manager, settings: settings, root: downloadsRoot,
                makeSession: makeDownloadSession)
            dataStack = stack
            accounts = manager
            lifecycle = SessionLifecycle(
                source: AccountSessionAdapter(accounts: manager) { await built.lifecycle.connectionRemoved($0) })
            lifecycle.register(built.lifecycle, stage: .connect)
            downloads = built
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
        self.downloads = downloads
        downloads?.lifecycle.launch()
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
