import ABSAPI
import ABSAppModel
import ABSCore
import ABSPlayback
import Foundation
import Testing

@testable import ABSData
@testable import Audiobookshelf

private struct QueueTestDevice: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

/// Records the connections a removal handler was called for.
@MainActor
private final class Removals {
    var connectionIDs: [UUID] = []
}

/// The app's play-queue wiring (#156): each account scope's queue is saved in the settings'
/// defaults, and a removal the store commits deletes that connection's saved queue only.
@MainActor
@Suite struct PlaybackQueueWiringTests {
    private let a = UUID()
    private let b = UUID()

    /// Settings in a throwaway defaults suite, so a test never touches the app's.
    private func withSettings(_ body: (AppSettings) async throws -> Void) async throws {
        let suiteName = "PlaybackQueueWiringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(AppSettings(defaults: defaults))
    }

    private func item(_ id: String) -> QueueItem { QueueItem(libraryItemID: id, title: id) }

    /// The environment's removal deletes the removed connection's queue and keeps the others'.
    @Test func removingAConnectionDeletesOnlyItsQueue() async throws {
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(), downloadsRoot: nil)
            let accounts = try #require(environment.accounts)
            let store = AppPlayback.queueStore(settings: settings)
            store.save([item("1"), item("2")], serverConnectionID: a)
            store.save([item("3")], serverConnectionID: b)

            accounts.connectionRemoved?(a)

            #expect(store.load(serverConnectionID: a).isEmpty)
            #expect(store.load(serverConnectionID: b) == [item("3")])
        }
    }

    /// A removal whose database commit fails keeps the connection listed, so it keeps its saved
    /// queue too; removing it again, which commits, deletes the queue. Through `remove(_:)` itself,
    /// over the app's wiring.
    @Test(arguments: [true, false])
    func aRemovalKeepsTheQueueUnlessItCommits(commitFails: Bool) async throws {
        try await withSettings { settings in
            let host = "\(UUID().uuidString.lowercased()).connect-ui.test"
            defer { ConnectTestProtocol.forget(host) }
            let connections = ServerConnectionStore(modelContainer: try DataStack(location: .inMemory).container)
            let accounts = AccountManager(
                store: connections, keychain: ConnectTestKeychain(),
                validator: ServerValidator(sessionConfiguration: ConnectTestProtocol.configuration),
                sessionConfiguration: ConnectTestProtocol.configuration)
            let queues = AppPlayback.queueStore(settings: settings)
            AppPlayback.removesQueues(of: accounts, from: queues)
            let validated = try await ServerValidator(sessionConfiguration: ConnectTestProtocol.configuration)
                .validate(address: "https://\(host)")
            try await accounts.connect(local: validated, username: "reader", password: "pw")
            let id = try #require(accounts.activeConnection).id
            queues.save([item("1")], serverConnectionID: id)

            if commitFails {
                await connections.failNextCommit(with: CocoaError(.fileWriteNoPermission))
                await #expect(throws: CocoaError.self) { try await accounts.remove(id) }
                #expect(accounts.connections.map(\.id) == [id])
                #expect(queues.load(serverConnectionID: id) == [item("1")])
            }

            try await accounts.remove(id)
            #expect(accounts.connections.isEmpty)
            #expect(queues.load(serverConnectionID: id).isEmpty)
        }
    }

    /// A handler already set still runs, before the queue goes.
    @Test func removalKeepsTheHandlerAlreadySet() async throws {
        try await withSettings { settings in
            let environment = AppEnvironment(
                settings: settings, storeLocation: .inMemory, keychain: ConnectTestKeychain(), downloadsRoot: nil)
            let accounts = try #require(environment.accounts)
            let store = AppPlayback.queueStore(settings: settings)
            store.save([item("1")], serverConnectionID: a)
            let removals = Removals()
            accounts.connectionRemoved = { connectionID in
                // Not deleted yet: the earlier handler runs first.
                #expect(!store.load(serverConnectionID: connectionID).isEmpty)
                removals.connectionIDs.append(connectionID)
            }

            AppPlayback.removesQueues(of: accounts, from: store)
            accounts.connectionRemoved?(a)

            #expect(removals.connectionIDs == [a])
            #expect(store.load(serverConnectionID: a).isEmpty)
        }
    }

    /// An account's scope loads the connection's saved queue from the settings' defaults, with its
    /// advancer attached (the scope's queue is the advancer's), and saves its changes there.
    @Test func eachScopeKeepsItsConnectionsQueueInTheSettings() async throws {
        try await withSettings { settings in
            let store = AppPlayback.queueStore(settings: settings)
            store.save([item("1"), item("2")], serverConnectionID: a)
            store.save([item("3")], serverConnectionID: b)
            let request = PlaybackScopeRequest(
                connectionID: a, client: nil, features: nil, deviceIdentifiers: QueueTestDevice(),
                writer: LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container))
            let monitor = NetworkMonitor()
            let scope = AppPlayback.makeScope(
                for: request, settings: settings, policy: NetworkPolicy(monitor: monitor, settings: settings),
                mediaLeases: nil, history: nil)
            defer { scope.retire(reason: .signOut) }

            #expect(scope.queue?.serverConnectionID == a)
            #expect(scope.queue?.items == [item("1"), item("2")])

            scope.editQueue { $0.move(fromOffsets: [1], toOffset: 0) }

            #expect(store.load(serverConnectionID: a) == [item("2"), item("1")])
            #expect(store.load(serverConnectionID: b) == [item("3")])
        }
    }
}
