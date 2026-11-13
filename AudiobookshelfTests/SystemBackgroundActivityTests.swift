import ABSAppModel
import ABSCore
import ABSData
import ABSPlayback
import Foundation
import Testing

@testable import Audiobookshelf

/// ``SystemBackgroundActivity`` over fake system background tasks (#160): every grant is
/// ended exactly once, by the caller or by the expiration handler.
@MainActor
@Suite struct SystemBackgroundActivityTests {
    /// Records grants and ends; hands out increasing identifiers, or refuses when asked to.
    @MainActor
    final class FakeTasks {
        var refuses = false
        private(set) var begun: [(name: String, identifier: Int)] = []
        private(set) var ended: [Int] = []
        private var expirations: [Int: @MainActor @Sendable () -> Void] = [:]
        private var next = 1

        var tasks: BackgroundTasks {
            BackgroundTasks(
                begin: { [self] name, expiration in
                    guard !refuses else { return nil }
                    let identifier = next
                    next += 1
                    begun.append((name, identifier))
                    expirations[identifier] = expiration
                    return identifier
                },
                end: { [self] in ended.append($0) })
        }

        /// The system's time for `identifier` runs out.
        func expire(_ identifier: Int) { expirations[identifier]?() }
    }

    @Test func beginHoldsAGrantUntilItsEnd() {
        let fake = FakeTasks()
        let activity = SystemBackgroundActivity(tasks: fake.tasks)

        let first = activity.begin(name: "Auto-advance")
        let second = activity.begin(name: "Auto-advance")
        #expect(fake.begun.map(\.name) == ["Auto-advance", "Auto-advance"])
        #expect(activity.heldCount == 2)

        activity.end(second)
        activity.end(first)
        #expect(fake.ended == [2, 1])
        #expect(activity.heldCount == 0)
    }

    @Test func endingTwiceEndsTheGrantOnce() {
        let fake = FakeTasks()
        let activity = SystemBackgroundActivity(tasks: fake.tasks)

        let token = activity.begin(name: "Auto-advance")
        activity.end(token)
        activity.end(token)

        #expect(fake.ended == [1])
    }

    /// iOS requires the expiration handler to end the grant; the caller's later end does nothing.
    @Test func expiryEndsTheGrantAndTheLaterEndIsIgnored() {
        let fake = FakeTasks()
        let activity = SystemBackgroundActivity(tasks: fake.tasks)
        let token = activity.begin(name: "Auto-advance")

        fake.expire(1)
        #expect(fake.ended == [1])
        #expect(activity.heldCount == 0)

        activity.end(token)
        #expect(fake.ended == [1])
    }

    /// A grant the system refuses holds nothing, so there's nothing to end.
    @Test func aRefusedGrantEndsNothing() {
        let fake = FakeTasks()
        fake.refuses = true
        let activity = SystemBackgroundActivity(tasks: fake.tasks)

        let token = activity.begin(name: "Auto-advance")
        activity.end(token)

        #expect(activity.heldCount == 0)
        #expect(fake.ended.isEmpty)
    }

    /// Each scope's coordinator holds the system's background tasks on iOS, and nothing on the
    /// Mac, which doesn't suspend the app.
    @Test func scopesHoldThePlatformsBackgroundActivity() throws {
        let suiteName = "SystemBackgroundActivityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let request = PlaybackScopeRequest(
            connectionID: UUID(), client: nil, features: nil, deviceIdentifiers: FixedDevice(),
            writer: LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container))

        let configuration = AppPlayback.configuration(
            for: request, settings: settings, policy: NetworkPolicy(monitor: NetworkMonitor(), settings: settings),
            engine: AudioEngine(audioSession: nil))

        #if os(iOS)
            #expect(configuration.backgroundActivity is SystemBackgroundActivity)
        #else
            #expect(configuration.backgroundActivity is NoBackgroundActivity)
        #endif
    }

    /// The environment hands the library's progress changes to playback's auto-advance.
    @Test func theLibrarysProgressReachesPlayback() async throws {
        let suiteName = "SystemBackgroundActivityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let environment = AppEnvironment(
            settings: AppSettings(defaults: defaults), storeLocation: .inMemory, keychain: ConnectTestKeychain(),
            downloadsRoot: nil)

        let library = try #require(environment.library)
        #expect(library.store.progress.onChange != nil)
    }

    private struct FixedDevice: DeviceIdentifying {
        func deviceIdentifier() async -> String { "device" }
    }
}
