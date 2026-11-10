import Foundation
import Observation
import Synchronization
import Testing

@testable import ABSCore

/// Runs `body` with a fresh, uniquely named `UserDefaults` suite and removes it afterwards.
@MainActor
private func withIsolatedDefaults(_ body: @MainActor (UserDefaults, String) async throws -> Void) async throws {
    let suiteName = "ABSCoreTests.AppSettings.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try await body(defaults, suiteName)
}

/// Polls `condition` on the main actor until it holds or about two seconds pass.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A Sendable flag set from an observation `onChange` handler.
private final class Flag: Sendable {
    private let storage = Mutex(false)
    var isSet: Bool { storage.withLock { $0 } }
    func set() { storage.withLock { $0 = true } }
}

@MainActor
private func trackChange(of read: @escaping @MainActor () -> Void) -> Flag {
    let flag = Flag()
    withObservationTracking(read, onChange: { flag.set() })
    return flag
}

@MainActor
@Suite struct AppSettingsTests {
    @Test func freshStoreHasLegacyDefaults() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.enableAltView == true)
            #expect(settings.theme == .system)
            #expect(settings.hapticFeedback == .light)
            #expect(settings.jumpForwardTime == 10)
            #expect(settings.jumpBackwardsTime == 10)
            #expect(settings.disableAutoRewind == false)
            #expect(settings.enableMp3IndexSeeking == false)
            #expect(settings.allowSeekingOnMediaControls == false)
            #expect(settings.sleepTimerLength == 900_000)
            #expect(settings.disableShakeToResetSleepTimer == false)
            #expect(settings.shakeSensitivity == .medium)
            #expect(settings.disableSleepTimerFadeOut == false)
            #expect(settings.disableSleepTimerResetFeedback == false)
            #expect(settings.enableSleepTimerAlmostDoneChime == false)
            #expect(settings.autoSleepTimer == false)
            #expect(settings.autoSleepTimerStartTime == "22:00")
            #expect(settings.autoSleepTimerEndTime == "06:00")
            #expect(settings.autoSleepTimerAutoRewind == false)
            #expect(settings.autoSleepTimerAutoRewindTime == 300_000)
            #expect(settings.downloadUsingCellular == .always)
            #expect(settings.streamingUsingCellular == .always)
            #expect(settings.playbackRate == 1.0)
            #expect(settings.chapterTrack == true)
            #expect(settings.lastLibraryIDs.isEmpty)
            // Defaults are not written back.
            #expect(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
        }
    }

    @Test func keysAreUniqueAndKVOSafe() {
        let keys = AppSettings.Key.allCases.map(\.rawValue)
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { !$0.contains(".") && !$0.isEmpty })
    }

    @Test func valuesRoundTripAsPropertyListTypes() async throws {
        try await withIsolatedDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            settings.enableAltView = false
            settings.theme = .black
            settings.hapticFeedback = .heavy
            settings.jumpForwardTime = 30
            settings.jumpBackwardsTime = 5
            settings.disableAutoRewind = true
            settings.enableMp3IndexSeeking = true
            settings.allowSeekingOnMediaControls = true
            settings.sleepTimerLength = 0
            settings.disableShakeToResetSleepTimer = true
            settings.shakeSensitivity = .veryHigh
            settings.disableSleepTimerFadeOut = true
            settings.disableSleepTimerResetFeedback = true
            settings.enableSleepTimerAlmostDoneChime = true
            settings.autoSleepTimer = true
            settings.autoSleepTimerStartTime = "21:30"
            settings.autoSleepTimerEndTime = "07:15"
            settings.autoSleepTimerAutoRewind = true
            settings.autoSleepTimerAutoRewindTime = 600_000
            settings.downloadUsingCellular = .never
            settings.streamingUsingCellular = .ask
            settings.playbackRate = 1.75
            settings.chapterTrack = false
            settings.setLastLibraryID("lib-1", serverID: "server-a", userID: "user-1")

            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.enableAltView == false)
            #expect(reloaded.theme == .black)
            #expect(reloaded.hapticFeedback == .heavy)
            #expect(reloaded.jumpForwardTime == 30)
            #expect(reloaded.jumpBackwardsTime == 5)
            #expect(reloaded.disableAutoRewind == true)
            #expect(reloaded.enableMp3IndexSeeking == true)
            #expect(reloaded.allowSeekingOnMediaControls == true)
            #expect(reloaded.sleepTimerLength == 0)
            #expect(reloaded.disableShakeToResetSleepTimer == true)
            #expect(reloaded.shakeSensitivity == .veryHigh)
            #expect(reloaded.disableSleepTimerFadeOut == true)
            #expect(reloaded.disableSleepTimerResetFeedback == true)
            #expect(reloaded.enableSleepTimerAlmostDoneChime == true)
            #expect(reloaded.autoSleepTimer == true)
            #expect(reloaded.autoSleepTimerStartTime == "21:30")
            #expect(reloaded.autoSleepTimerEndTime == "07:15")
            #expect(reloaded.autoSleepTimerAutoRewind == true)
            #expect(reloaded.autoSleepTimerAutoRewindTime == 600_000)
            #expect(reloaded.downloadUsingCellular == .never)
            #expect(reloaded.streamingUsingCellular == .ask)
            #expect(reloaded.playbackRate == 1.75)
            #expect(reloaded.chapterTrack == false)
            #expect(reloaded.lastLibraryID(serverID: "server-a", userID: "user-1") == "lib-1")

            // Stored as plain property-list values so @AppStorage can bind to them.
            #expect(defaults.string(forKey: AppSettings.Key.theme.rawValue) == "black")
            #expect(defaults.string(forKey: AppSettings.Key.shakeSensitivity.rawValue) == "VERY_HIGH")
            #expect(defaults.string(forKey: AppSettings.Key.downloadUsingCellular.rawValue) == "NEVER")
            #expect(defaults.object(forKey: AppSettings.Key.jumpForwardTime.rawValue) as? Int == 30)
            #expect(defaults.object(forKey: AppSettings.Key.playbackRate.rawValue) as? Double == 1.75)
            #expect(defaults.object(forKey: AppSettings.Key.chapterTrack.rawValue) as? Bool == false)
        }
    }

    @Test func invalidStoredValuesFallBackToDefaults() async throws {
        try await withIsolatedDefaults { defaults, _ in
            func store(_ value: Any, _ key: AppSettings.Key) { defaults.set(value, forKey: key.rawValue) }
            store("yes", .enableAltView)
            store("sepia", .theme)
            store(42, .hapticFeedback)
            store(0, .jumpForwardTime)
            store("ten", .jumpBackwardsTime)
            store(-1, .sleepTimerLength)
            store("loud", .shakeSensitivity)
            store("25:00", .autoSleepTimerStartTime)
            store("6:00", .autoSleepTimerEndTime)
            store(10.5, .autoSleepTimerAutoRewindTime)
            store("sometimes", .downloadUsingCellular)
            store(0.0, .playbackRate)
            store(["a", "b"], .lastLibraryIDs)

            let settings = AppSettings(defaults: defaults)
            #expect(settings.enableAltView == true)
            #expect(settings.theme == .system)
            #expect(settings.hapticFeedback == .light)
            #expect(settings.jumpForwardTime == 10)
            #expect(settings.jumpBackwardsTime == 10)
            #expect(settings.sleepTimerLength == 900_000)
            #expect(settings.shakeSensitivity == .medium)
            #expect(settings.autoSleepTimerStartTime == "22:00")
            #expect(settings.autoSleepTimerEndTime == "06:00")
            #expect(settings.autoSleepTimerAutoRewindTime == 300_000)
            #expect(settings.downloadUsingCellular == .always)
            #expect(settings.playbackRate == 1.0)
            #expect(settings.lastLibraryIDs.isEmpty)

            store(-Double.infinity, .playbackRate)
            #expect(settings.playbackRate == 1.0)
        }
    }

    @Test func inProcessWritesNotifyObservers() async throws {
        try await withIsolatedDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            let rate = trackChange { _ = settings.playbackRate }
            let theme = trackChange { _ = settings.theme }
            settings.playbackRate = 2.0
            #expect(rate.isSet)
            #expect(!theme.isSet)
        }
    }

    @Test func externalWritesAreObserved() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            let settings = AppSettings(defaults: defaults)
            let jump = trackChange { _ = settings.jumpForwardTime }
            let other = trackChange { _ = settings.chapterTrack }

            // Another UserDefaults instance for the same suite, as @AppStorage or a second
            // scene would use.
            let external = try #require(UserDefaults(suiteName: suiteName))
            external.set(60, forKey: AppSettings.Key.jumpForwardTime.rawValue)
            #expect(await eventually { settings.jumpForwardTime == 60 })
            #expect(jump.isSet)
            #expect(!other.isSet)

            external.removeObject(forKey: AppSettings.Key.jumpForwardTime.rawValue)
            #expect(await eventually { settings.jumpForwardTime == 10 })
        }
    }

    @Test func writesFromAnotherThreadAreObserved() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            let settings = AppSettings(defaults: defaults)
            let task = Task.detached {
                UserDefaults(suiteName: suiteName)?.set(
                    "NEVER", forKey: AppSettings.Key.streamingUsingCellular.rawValue)
            }
            await task.value
            #expect(await eventually { settings.streamingUsingCellular == .never })
        }
    }

    @Test func lastLibraryIsPerServerAndUser() async throws {
        try await withIsolatedDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            settings.setLastLibraryID("lib-a1", serverID: "a", userID: "1")
            settings.setLastLibraryID("lib-a2", serverID: "a", userID: "2")
            settings.setLastLibraryID("lib-b1", serverID: "b", userID: "1")
            #expect(settings.lastLibraryID(serverID: "a", userID: "1") == "lib-a1")
            #expect(settings.lastLibraryID(serverID: "a", userID: "2") == "lib-a2")
            #expect(settings.lastLibraryID(serverID: "b", userID: "1") == "lib-b1")
            #expect(settings.lastLibraryID(serverID: "c", userID: "1") == nil)

            let changed = trackChange { _ = settings.lastLibraryID(serverID: "a", userID: "1") }
            settings.setLastLibraryID(nil, serverID: "a", userID: "1")
            #expect(changed.isSet)
            #expect(AppSettings(defaults: defaults).lastLibraryID(serverID: "a", userID: "1") == nil)
            #expect(AppSettings(defaults: defaults).lastLibraryID(serverID: "a", userID: "2") == "lib-a2")
        }
    }

    @Test func fallsBackToStandardDefaultsWithoutAppGroup() {
        let defaults = AppSettings.sharedDefaults(appGroupIdentifier: "group.test.unavailable") { _ in false }
        #expect(defaults === UserDefaults.standard)
    }

    @Test func usesTheAppGroupSuiteWhenAvailable() {
        let identifier = "group.ABSCoreTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: identifier) }
        let defaults = AppSettings.sharedDefaults(appGroupIdentifier: identifier) { $0 == identifier }
        #expect(defaults !== UserDefaults.standard)
        defaults.set(true, forKey: AppSettings.Key.autoSleepTimer.rawValue)
        #expect(UserDefaults(suiteName: identifier)?.bool(forKey: AppSettings.Key.autoSleepTimer.rawValue) == true)
        defaults.removePersistentDomain(forName: identifier)
    }

    #if os(macOS)
        @Test func unentitledProcessHasNoAppGroup() {
            // `swift test` runs without entitlements, like the ad hoc signed app test host.
            #expect(!AppSettings.isAppGroupAvailable(AppSettings.appGroupIdentifier))
        }
    #endif

    @Test(arguments: ["00:00", "23:59", "06:00"])
    func acceptsTimesOfDay(_ value: String) {
        #expect(AppSettings.isTimeOfDay(value))
    }

    @Test(arguments: ["24:00", "12:60", "6:00", "12:5", "ab:cd", "1200", "12:00:00", ""])
    func rejectsInvalidTimesOfDay(_ value: String) {
        #expect(!AppSettings.isTimeOfDay(value))
    }
}
