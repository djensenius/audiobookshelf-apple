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
    /// Built on first use, so a process that never asks for it opens no store. A Debug build
    /// launched with `-ABSFixtures` gets ``FixtureServer``'s in-memory environment instead. The
    /// app test host (`mise run test:app`) leaves out the download stack: its store holds the
    /// app's real downloads, which it mustn't restart or sweep, and tests build their own.
    static let shared: AppEnvironment = {
        #if DEBUG
            if FixtureServer.isEnabled { return FixtureServer.environment() }
        #endif
        return AppEnvironment(
            downloadsRoot: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
                ? .applicationSupportDirectory : nil)
    }()

    let settings: AppSettings
    /// The on-device store, or `nil` when it couldn't be opened. ``lifecycle`` then shows
    /// ``AuthGate/storeUnavailable(_:)``, because nothing can be restored or saved.
    let dataStack: DataStack?
    let accounts: AccountManager?
    /// The one writer of local listening progress (`LocalProgressStore` must be shared), or `nil`
    /// when the store couldn't be opened. Downloads link their progress rows in it (#74).
    let localProgress: LocalProgressStore?
    let lifecycle: SessionLifecycle
    /// The stable device ID for playback sessions (ADR 0007), kept in the same Keychain as the
    /// accounts. It doesn't need the store, so it exists even when ``dataStack`` is `nil`.
    let deviceIdentifiers: any DeviceIdentifying
    /// The one player every scene and CarPlay share: ``playback``'s, idle between sessions.
    let player: PlayerViewModel
    /// Each signed-in account's playback scope and the player's playback (#183).
    let playback: AppPlayback
    /// The download stack, or `nil` when the store couldn't be opened. Its lifecycle is
    /// launched here, so a launch without a window (CarPlay, a background wake) has an engine.
    let downloads: AppDownloads?
    /// The shared library and its session participant (#181), or `nil` without ``accounts``.
    let library: LibraryParticipant?
    /// The cover image pipeline and its session participant (#182).
    let images: ImageServices
    /// Writes the Continue Listening widget's snapshot (#89).
    let widgetSnapshots: WidgetSnapshotWriter

    /// - Parameters:
    ///   - settings: The settings every scene shares.
    ///   - storeLocation: Where the store lives; tests and previews pass `.inMemory`.
    ///   - downloadsRoot: Where downloads live (``AppDownloads/make(dataStack:accounts:settings:root:makeSession:progress:)``);
    ///     tests pass a temporary directory, and `nil` leaves out the download stack.
    ///   - makeDownloadSession: The download engine's session; tests pass a non-background one.
    ///   - covers: Where the cover pipeline fetches and caches covers.
    init(
        settings: AppSettings = AppSettings(), storeLocation: DataStack.Location = .appGroup,
        keychain: any KeychainStoring = KeychainStore(),
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .absConnection() },
        downloadsRoot: URL? = .applicationSupportDirectory,
        makeDownloadSession: @escaping DownloadSessionFactory = DownloadEngine.backgroundSession(),
        covers: CoverSource = .app
    ) {
        let dataStack: DataStack?
        let accounts: AccountManager?
        let localProgress: LocalProgressStore?
        let lifecycle: SessionLifecycle
        var downloads: AppDownloads?
        do {
            let stack = try DataStack(location: storeLocation)
            let manager = AccountManager(
                store: ServerConnectionStore(modelContainer: stack.container), keychain: keychain,
                validator: ServerValidator(sessionConfiguration: sessionConfiguration),
                openID: OIDCLoginService(sessionConfiguration: sessionConfiguration),
                sessionConfiguration: sessionConfiguration, settings: settings)
            let progress = LocalProgressStore(modelContainer: stack.container)
            downloads = downloadsRoot.map {
                AppDownloads.make(
                    dataStack: stack, accounts: manager, settings: settings, root: $0, makeSession: makeDownloadSession,
                    progress: progress)
            }
            dataStack = stack
            accounts = manager
            localProgress = progress
            lifecycle = SessionLifecycle(source: AccountSessionAdapter(accounts: manager))
            if let downloads {
                lifecycle.register(downloads.lifecycle, stage: .connect)
                // A removal stops the downloads once the credentials are deleted, active or not.
                manager.credentialsRemoved = { [weak downloadsLifecycle = downloads.lifecycle] in
                    await downloadsLifecycle?.connectionRemoved($0)
                }
                // So does every expiry, whether or not a session of it is ending.
                manager.credentialsExpired = { [weak downloadsLifecycle = downloads.lifecycle] in
                    downloadsLifecycle?.connectionExpired($0)
                }
            }
        } catch {
            let reason = Log.redact(String(describing: error))
            Log.data.fault("The on-device store couldn't be opened: \(reason, privacy: .public)")
            dataStack = nil
            accounts = nil
            localProgress = nil
            lifecycle = SessionLifecycle(storeUnavailable: error)
        }
        self.settings = settings
        self.dataStack = dataStack
        self.accounts = accounts
        self.localProgress = localProgress
        self.lifecycle = lifecycle
        let deviceIdentifiers = DeviceIdentifierStore(keychain: keychain)
        self.deviceIdentifiers = deviceIdentifiers
        let playback = AppPlayback.make(
            dataStack: dataStack, accounts: accounts, lifecycle: lifecycle, settings: settings,
            deviceIdentifiers: deviceIdentifiers)
        self.playback = playback
        self.player = playback.player
        self.downloads = downloads
        downloads?.lifecycle.launch()
        self.library = accounts.map {
            Self.makeLibrary(settings: settings, accounts: $0, lifecycle: lifecycle, playback: playback)
        }

        // Images (#182).
        let images = ImageServices(
            accounts: accounts, sweepsRemovedConnections: dataStack?.resolvedLocation == .appGroup, covers: covers)
        lifecycle.register(images.participant, stage: .connect)
        self.images = images

        // Widgets (#89).
        let widgetSnapshots = Self.makeWidgetSnapshotWriter(
            accounts: accounts, lifecycle: lifecycle, storeLocation: storeLocation)
        lifecycle.register(widgetSnapshots, stage: .connect)
        // The app's one player, across every account's session: its item and play state.
        widgetSnapshots.follow(playback.player)
        self.widgetSnapshots = widgetSnapshots
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
