import ABSAppModel
import ABSCore
import ABSData
import ABSDownloads
import ABSPlayback
import ABSUI
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Audiobookshelf

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// Downloads for an `AppEnvironment` built by a test: a throwaway root, never the app's
/// container, and a session that isn't the app's background one.
struct TestDownloads {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "AppEnvironmentTests-Downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
    let makeSession: DownloadSessionFactory = {
        URLSession(configuration: .ephemeral, delegate: $0, delegateQueue: nil)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
@Suite struct AppEnvironmentTests {
    private let downloads = TestDownloads()

    /// Settings in a throwaway defaults suite, so a test never touches the app's.
    private func withSettings(_ body: (AppSettings) async throws -> Void) async throws {
        let suiteName = "AppEnvironmentTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            downloads.cleanUp()
        }
        try await body(AppSettings(defaults: defaults))
    }

    @Test func buildsWithAnInMemoryStoreAndSettlesSignedOut() async throws {
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(),
                downloadsRoot: downloads.root, makeDownloadSession: downloads.makeSession)

            #expect(environment.settings === settings)
            #expect(environment.dataStack != nil)
            #expect(environment.accounts != nil)
            #expect(environment.downloads != nil)
            // The library is the lifecycle's seeder, and stays cleared while signed out.
            #expect(environment.library != nil)
            #expect(environment.realtime?.bridge.connectionState == .idle)
            // Socket progress merges through the environment's one writer.
            #expect(environment.realtime?.bridge.localProgress === environment.localProgress)
            #expect(environment.lifecycle.gate == .launching)

            await environment.lifecycle.start()

            #expect(environment.lifecycle.gate == .connect)
            #expect(environment.library?.store.connectionKey == nil)
        }
    }

    /// A test or fixture environment settles signed out, which clears the widget's snapshot; only
    /// the App Group store's may touch the shared snapshot and the user's widget.
    @Test func anInMemoryEnvironmentLeavesTheWidgetAlone() async throws {
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(), downloadsRoot: nil)

            #expect(environment.widgetSnapshots.fileURL == nil)
            #expect(environment.widgetSnapshots.reloader is NoWidgetReloads)
        }
    }

    /// The writer's observers must not keep a released environment's lifecycle, and so the
    /// writer itself, alive.
    @Test func aReleasedEnvironmentReleasesItsWidgetWriter() async throws {
        try await withSettings { settings in
            weak var lifecycle: SessionLifecycle?
            weak var writer: WidgetSnapshotWriter?
            do {
                let environment = AppEnvironment(
                    settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(), downloadsRoot: nil)
                lifecycle = environment.lifecycle
                writer = environment.widgetSnapshots
                for _ in 0..<100 { await Task.yield() }
            }
            for _ in 0..<100 { await Task.yield() }

            #expect(writer == nil)
            #expect(lifecycle == nil)
        }
    }

    /// Built with the environment and launched without a scene, so a CarPlay-only launch or a
    /// background wake has a running download stack.
    @Test func launchesTheDownloadStackInTheInjectedRoot() async throws {
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(),
                downloadsRoot: downloads.root, makeDownloadSession: downloads.makeSession)
            let stack = try #require(environment.downloads)
            // A removal stops the downloads once its credentials are deleted.
            #expect(environment.accounts?.credentialsRemoved != nil)
            // A sign-in over a saved session stops and resumes them (#386).
            #expect(environment.accounts?.credentialsReplaced != nil)

            // The launch the environment began; the same task, so this waits for it.
            await stack.lifecycle.launch().value

            let locations = DownloadLocations(root: downloads.root)
            for folder in [locations.downloadsRoot, locations.resumeDataRoot] {
                #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)), "\(folder)")
            }
        }
    }

    /// The app test host's environment: no download stack, so its real downloads stay as they are.
    @Test func withoutADownloadsRootLeavesOutTheDownloadStack() async throws {
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(), downloadsRoot: nil,
                makeDownloadSession: downloads.makeSession)

            #expect(environment.accounts != nil)
            #expect(environment.downloads == nil)
            // Only Spotlight's recent items are deleted on a removal (RecentItemsDonorTests).
            #expect(environment.accounts?.credentialsRemoved != nil)
            // A committed removal still deletes the saved play queue (PlaybackQueueWiringTests).
            #expect(environment.accounts?.connectionRemoved != nil)

            await environment.lifecycle.start()

            #expect(environment.lifecycle.gate == .connect)
        }
    }

    /// The cover pipeline reads downloaded items' covers through the download stack, and has no
    /// downloaded covers without one (#143).
    @Test func imagesReadDownloadedCoversOnlyWithADownloadStack() async throws {
        try await withSettings { settings in
            let withDownloads = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(),
                downloadsRoot: downloads.root, makeDownloadSession: downloads.makeSession)
            #expect(withDownloads.images.downloadedCovers is LocalDownloadedCovers)

            let without = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(), downloadsRoot: nil)
            #expect(without.images.downloadedCovers == nil)
        }
    }

    /// A downloaded item's cover loads from its file in the downloads root, offline, through the
    /// environment's shared pipeline, and isn't copied into the cover cache.
    @Test func aDownloadedItemsCoverLoadsOfflineFromItsFile() async throws {
        let covers = FileManager.default.temporaryDirectory.appending(
            path: "AppEnvironmentTests-Covers-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: covers) }
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(),
                downloadsRoot: downloads.root, makeDownloadSession: downloads.makeSession,
                covers: CoverSource(directory: covers, isOnline: { false }))
            let stack = try #require(environment.downloads)
            await stack.lifecycle.launch().value
            let container = try #require(environment.dataStack).container
            let connection = try await ServerConnectionStore(modelContainer: container).upsertLogin(
                address: try #require(ServerAddress("https://abs.example.com")), userId: "usr_1", username: "user",
                authMethod: .local, serverVersion: nil)
            let coverUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
            _ = try await stack.localItems.upsertFromDownload(
                DownloadRecordDTO(
                    key: MediaKey(serverConnectionID: connection.id, libraryItemId: "li_1"), mediaType: .book,
                    title: "The Book", relativeDirectory: "li_1",
                    media: LocalMediaSnapshot(metadata: .init(title: "The Book")),
                    parts: [
                        DownloadPartDTO(
                            kind: .cover, serverPath: "/api/items/li_1/cover", filename: "cover.jpg",
                            mimeType: "image/jpeg", destinationRelativePath: "li_1/cover.jpg", state: .completed),
                        DownloadPartDTO(
                            kind: .audio, serverPath: "/api/items/li_1/file", filename: "part1.mp3",
                            mimeType: "audio/mpeg", destinationRelativePath: "li_1/part1.mp3", state: .completed),
                    ]),
                coverUpdatedAt: coverUpdatedAt)
            let file = try DownloadLocations(root: downloads.root).fileURL(forRelativePath: "li_1/cover.jpg")
            try Self.writeJPEG(width: 120, height: 180, to: file)

            let key = ImageKey(
                serverID: connection.id, kind: .itemCover, entityID: "li_1",
                updatedAt: LocalDownloadedCovers.version(of: coverUpdatedAt))
            let image = try await environment.images.pipeline.image(
                for: key, pixelBox: PixelBox(width: 512, height: 832))

            #expect(image.pixelWidth == 120)
            #expect(image.pixelHeight == 180)
            let cached =
                FileManager.default.enumerator(at: covers, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
            #expect(cached.isEmpty)
        }
    }

    /// A solid JPEG of the given size at `url`, creating its folder.
    private static func writeJPEG(width: Int, height: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// A store other than the App Group one may not list the connections whose covers share the
    /// App Group cover cache, so the launch sweep mustn't delete covers from it.
    @Test func onlyTheAppGroupStoreSweepsRemovedConnectionsCovers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "AppEnvironmentTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withSettings { settings in
            let inMemory = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(), downloadsRoot: nil)
            #expect(inMemory.accounts != nil)
            #expect(!inMemory.images.sweepsRemovedConnections)

            let onDisk = AppEnvironment(
                settings: settings, storeLocation: .url(directory.appending(path: "Audiobookshelf.store")),
                keychain: ConnectTestKeychain(), downloadsRoot: nil)
            #expect(onDisk.accounts != nil)
            #expect(!onDisk.images.sweepsRemovedConnections)
        }
    }

    /// One player for every scene and CarPlay, idle until an account session binds it.
    @Test func playerIsAnIdleProcessWidePlayerViewModel() async throws {
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(), downloadsRoot: nil)

            #expect(environment.player === environment.playback.player)
            #expect(!environment.player.hasSession)
            #expect(environment.player.errorMessageKey == nil)

            await environment.lifecycle.start()

            // Signed out: no scope, so nothing to play.
            #expect(environment.lifecycle.gate == .connect)
            #expect(environment.playback.participant?.playItem == nil)
            #expect(!environment.player.hasSession)
        }
    }

    /// The data environment's one progress writer, which the participant hands every account's
    /// scope, so a retired scope's late write can't replace a newer one. It's the same store
    /// downloads link progress through (ADR 0003: one shared writer).
    @Test func playbackHoldsOneWriter() async throws {
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(), downloadsRoot: nil)

            let writer = try #require(environment.playback.writer)
            #expect(writer === environment.localProgress)
            #expect(environment.playback.participant != nil)
        }
    }

    /// Each scope's recovery waits on the system's network path, not an always-online one.
    @Test func playbackScopesWaitOnTheNetworkPath() async throws {
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(), downloadsRoot: nil)
            let request = try scopeRequest(environment)

            let configuration = AppPlayback.configuration(
                for: request, settings: settings, policy: NetworkPolicy(monitor: NetworkMonitor(), settings: settings),
                engine: AudioEngine(audioSession: nil))

            #expect(configuration.networkPaths is SystemNetworkPathSource)
        }
    }

    /// Every scope's syncer records history through the environment's one history store (#184).
    @Test func playbackRecordsHistoryInTheEnvironmentsStore() async throws {
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(), downloadsRoot: nil)
            let store = try #require(environment.playbackHistory)
            let history = try #require(environment.playback.history)
            let configuration = AppPlayback.configuration(
                for: try scopeRequest(environment), settings: settings,
                policy: NetworkPolicy(monitor: NetworkMonitor(), settings: settings),
                engine: AudioEngine(audioSession: nil), history: history)
            let key = MediaKey(serverConnectionID: UUID(), libraryItemId: "li_book")

            await configuration.history?.record(.play, for: PlaybackHistoryMedia(key: key, displayTitle: "Book"), at: 5)

            #expect(try await store.events(for: key).map(\.name) == [.play])
        }
    }

    /// Launching prunes history past its retention, keeping the rest (ADR 0003).
    @Test func launchPrunesExpiredPlaybackHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "AppEnvironmentTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = DataStack.Location.url(directory.appending(path: "Audiobookshelf.store"))
        let key = MediaKey(serverConnectionID: UUID(), libraryItemId: "li_book")
        func event(_ name: PlaybackHistoryEventName, at timestamp: Date) -> PlaybackHistoryEventDTO {
            PlaybackHistoryEventDTO(
                serverConnectionID: key.serverConnectionID, mediaKey: key, mediaDisplayTitle: "Book", name: name,
                type: .playback, timestamp: timestamp)
        }
        do {
            let seeded = PlaybackHistoryStore(modelContainer: try DataStack(location: location).container)
            try await seeded.record(event(.play, at: .now.addingTimeInterval(-PlaybackHistoryStore.retention - 60)))
            try await seeded.record(event(.pause, at: .now.addingTimeInterval(-60)))
        }
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: location, keychain: ConnectTestKeychain(), downloadsRoot: nil)
            let store = try #require(environment.playbackHistory)

            await environment.historyPruning?.value

            #expect(try await store.events(for: key).map(\.name) == [.pause])
        }
    }

    /// The audio session's interruption handler gets the scope's coordinator, so an interruption
    /// also cancels a play the coordinator holds outside the engine (recovery, the initial load).
    @Test func playbackInterruptionsReachTheScopesCoordinator() async throws {
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(), downloadsRoot: nil)
            let request = try scopeRequest(environment)
            let interruptions = AudioInterruptionHandler()

            let scope = AppPlayback.makeScope(
                for: request, settings: settings, policy: NetworkPolicy(monitor: NetworkMonitor(), settings: settings),
                engine: AudioEngine(audioSession: nil), interruptions: interruptions)
            defer { scope.retire(reason: .signOut) }

            #expect(interruptions.heldPlayIntent === scope.coordinator)
        }
    }

    private func scopeRequest(_ environment: AppEnvironment) throws -> PlaybackScopeRequest {
        PlaybackScopeRequest(
            connectionID: UUID(), client: nil, features: nil, deviceIdentifiers: environment.deviceIdentifiers,
            writer: try #require(environment.localProgress))
    }

    @Test func keepsTheDeviceIdentifierInTheInjectedKeychain() async throws {
        try await withSettings { settings in
            let keychain = ConnectTestKeychain()
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: keychain, downloadsRoot: downloads.root,
                makeDownloadSession: downloads.makeSession)

            let identifier = await environment.deviceIdentifiers.deviceIdentifier()

            let stored = try #require(try keychain.data(for: DeviceIdentifierStore.item))
            #expect(String(decoding: stored, as: UTF8.self) == identifier)
            #expect(await environment.deviceIdentifiers.deviceIdentifier() == identifier)
        }
    }

    @Test func aStoreThatCantBeOpenedShowsStoreUnavailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "AppEnvironmentTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A regular file where the store's directory should be makes every load fail.
        let blocker = directory.appending(path: "Blocker")
        try Data().write(to: blocker)

        try await withSettings { settings in
            let location = DataStack.Location.url(blocker.appending(path: "Audiobookshelf.store"))
            let environment = AppEnvironment(
                settings: settings, storeLocation: location, keychain: ConnectTestKeychain(),
                downloadsRoot: downloads.root, makeDownloadSession: downloads.makeSession)

            #expect(environment.dataStack == nil)
            #expect(environment.accounts == nil)
            #expect(environment.downloads == nil)
            // The player still exists, idle, with no scope to bind it.
            #expect(environment.playback.participant == nil)
            #expect(environment.playback.writer == nil)
            #expect(!environment.player.hasSession)

            await environment.lifecycle.start()

            guard case .storeUnavailable = environment.lifecycle.gate else {
                Issue.record("Expected the store-unavailable gate, got \(environment.lifecycle.gate)")
                return
            }
        }
    }

    @Test func declaresTheHandoffActivityType() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String])

        #expect(types.contains(DeepLink.handoffActivityType))
    }

    @Test func registersTheLegacyURLScheme() throws {
        let identifier = try #require(Bundle.main.bundleIdentifier)
        let urlTypes = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])

        // ADR 0004: the legacy scheme, so links made for the old app open this one. It has to be
        // among the URL types, whatever else is registered.
        let urlType = try #require(
            urlTypes.first { ($0["CFBundleURLSchemes"] as? [String])?.contains("audiobookshelf") == true })
        #expect(urlType["CFBundleURLName"] as? String == identifier)
        #expect(urlType["CFBundleTypeRole"] as? String == "Editor")

        // What the app registers is what `DeepLink` accepts.
        let url = try #require(URL(string: "audiobookshelf://item/li_1"))
        #expect(DeepLink(url: url)?.target == .item(id: "li_1", episodeID: nil))
    }

    @Test func hostAppInfoPlistCarriesTheVersion() throws {
        // `PlaybackDeviceInfo` sends the host app's `CFBundleShortVersionString` to the server.
        let info = try #require(Bundle.main.infoDictionary)
        let marketing = try #require(info["CFBundleShortVersionString"] as? String)
        let build = try #require(info["CFBundleVersion"] as? String)

        let version = AppVersion()
        #expect(version.marketing == marketing)
        #expect(version.build == build)
        // Not AppVersion's fallback, so the host app's Info.plist was read.
        #expect(version != AppVersion(marketing: "0.0.0", build: "0"))
    }

    @Test(arguments: AppTab.allCases)
    func everyTabHasATitleAndASymbol(tab: AppTab) {
        #expect(L10n.string(tab.titleKey) != tab.titleKey, "\(tab) has no string for \(tab.titleKey)")
        #expect(symbolExists(tab.systemImage), "\(tab) has no SF Symbol named \(tab.systemImage)")
    }

    @Test(arguments: [
        "ButtonSwitchServer", "HeaderBrowse", "HeaderNowPlaying", "HeaderOpenLinkOnAnotherServer",
        "LabelMiniPlayerAccessibility", "LabelMiniPlayerHint", "MessageStoreUnavailable", "MessageStoreUnavailableHelp",
        "MessageSwitchServerForLink", "MessageSwitchServerSignedOut",
    ])
    func shellStringsResolve(key: String) {
        #expect(L10n.string(key) != key)
    }

    private func symbolExists(_ name: String) -> Bool {
        #if canImport(AppKit)
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
            UIImage(systemName: name) != nil
        #endif
    }
}
