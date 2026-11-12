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

/// Runs `write` on a background thread and blocks the caller until it finishes, so work the
/// write enqueues on the main actor can't run in between.
private func writeOnBackgroundThreadAndWait(_ write: @escaping @Sendable () -> Void) {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        write()
        done.signal()
    }
    done.wait()
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

    @Test func libraryViewPreferencesAreStoredPerAccountAndLibraryAndSurviveReload() async throws {
        try await withIsolatedDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            settings.setLibraryViewPreferencesJSON("{\"a\":1}", serverID: "s", userID: "u", libraryID: "lib-1")
            settings.setLibraryViewPreferencesJSON("{\"b\":2}", serverID: "s", userID: "u", libraryID: "lib-2")
            settings.setLibraryViewPreferencesJSON("{\"c\":3}", serverID: "s", userID: "other", libraryID: "lib-1")

            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.libraryViewPreferencesJSON(serverID: "s", userID: "u", libraryID: "lib-1") == "{\"a\":1}")
            #expect(reloaded.libraryViewPreferencesJSON(serverID: "s", userID: "u", libraryID: "lib-2") == "{\"b\":2}")
            #expect(
                AppSettings.snapshot(from: defaults).libraryViewPreferences
                    == [
                        AppSettings.libraryViewPreferencesKey(serverID: "s", userID: "u", libraryID: "lib-1"):
                            "{\"a\":1}",
                        AppSettings.libraryViewPreferencesKey(serverID: "s", userID: "u", libraryID: "lib-2"):
                            "{\"b\":2}",
                        AppSettings.libraryViewPreferencesKey(serverID: "s", userID: "other", libraryID: "lib-1"):
                            "{\"c\":3}",
                    ])

            settings.setLibraryViewPreferencesJSON(nil, serverID: "s", userID: "u", libraryID: "lib-1")
            #expect(settings.libraryViewPreferencesJSON(serverID: "s", userID: "u", libraryID: "lib-1") == nil)
            #expect(settings.libraryViewPreferencesJSON(serverID: "s", userID: "u", libraryID: "lib-2") != nil)

            defaults.set("not a dictionary", forKey: AppSettings.Key.libraryViewPreferences.rawValue)
            #expect(AppSettings(defaults: defaults).libraryViewPreferences.isEmpty)
        }
    }

    @Test func recentSearchesAreStoredPerAccountAndLibraryAndResetWithEverything() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            let settings = AppSettings(defaults: defaults)
            settings.setRecentSearchesJSON("[\"Dune\"]", serverID: "s", userID: "u", libraryID: "lib-1")
            settings.setRecentSearchesJSON("[\"Emma\"]", serverID: "s", userID: "u", libraryID: "lib-2")

            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.recentSearchesJSON(serverID: "s", userID: "u", libraryID: "lib-1") == "[\"Dune\"]")
            #expect(reloaded.recentSearchesJSON(serverID: "s", userID: "other", libraryID: "lib-1") == nil)
            #expect(AppSettings.snapshot(from: defaults).recentSearches.count == 2)

            // Another library's entry, written by another instance, survives a write.
            reloaded.setRecentSearchesJSON(nil, serverID: "s", userID: "u", libraryID: "lib-1")
            #expect(settings.recentSearchesJSON(serverID: "s", userID: "u", libraryID: "lib-2") == "[\"Emma\"]")
            #expect(reloaded.recentSearchesJSON(serverID: "s", userID: "u", libraryID: "lib-1") == nil)

            settings.resetAll()
            #expect(settings.recentSearches.isEmpty)
            #expect(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
        }
    }

    @Test func podcastEpisodeListPreferencesAreStoredOnceAndSurviveReload() async throws {
        try await withIsolatedDefaults { defaults, _ in
            let key = AppSettings.Key.podcastEpisodeListPreferences.rawValue
            let settings = AppSettings(defaults: defaults)
            #expect(settings.podcastEpisodeListPreferences == nil)
            #expect(AppSettings.snapshot(from: defaults).podcastEpisodeListPreferences == nil)

            settings.podcastEpisodeListPreferences = "{\"filter\":\"all\"}"
            #expect(defaults.string(forKey: key) == "{\"filter\":\"all\"}")
            #expect(AppSettings(defaults: defaults).podcastEpisodeListPreferences == "{\"filter\":\"all\"}")
            #expect(AppSettings.snapshot(from: defaults).podcastEpisodeListPreferences == "{\"filter\":\"all\"}")

            settings.podcastEpisodeListPreferences = nil
            #expect(defaults.object(forKey: key) == nil)
            #expect(AppSettings(defaults: defaults).podcastEpisodeListPreferences == nil)

            defaults.set(3, forKey: key)
            #expect(AppSettings(defaults: defaults).podcastEpisodeListPreferences == nil)
        }
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

    @Test func numbersAndBooleansDontCrossBridge() async throws {
        try await withIsolatedDefaults { defaults, _ in
            defaults.set(0, forKey: AppSettings.Key.enableAltView.rawValue)
            defaults.set(1, forKey: AppSettings.Key.chapterTrack.rawValue)
            defaults.set(false, forKey: AppSettings.Key.sleepTimerLength.rawValue)
            defaults.set(true, forKey: AppSettings.Key.jumpForwardTime.rawValue)
            defaults.set(true, forKey: AppSettings.Key.playbackRate.rawValue)

            let settings = AppSettings(defaults: defaults)
            #expect(settings.enableAltView == true)
            #expect(settings.chapterTrack == true)
            #expect(settings.sleepTimerLength == 900_000)
            #expect(settings.jumpForwardTime == 10)
            #expect(settings.playbackRate == 1.0)

            let snapshot = AppSettings.snapshot(from: defaults)
            #expect(snapshot.enableAltView == true)
            #expect(snapshot.sleepTimerLength == 900_000)
        }
    }

    @Test func setLastLibraryKeepsPendingExternalEntries() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            let settings = AppSettings(defaults: defaults)
            settings.setLastLibraryID("lib-a", serverID: "s", userID: "a")

            // Another account's entry is written off the main thread; its reload is queued on
            // the main actor, which stays blocked until setLastLibraryID below runs.
            writeOnBackgroundThreadAndWait {
                let external = UserDefaults(suiteName: suiteName)
                var stored = external?.dictionary(forKey: AppSettings.Key.lastLibraryIDs.rawValue) ?? [:]
                stored[AppSettings.accountKey(serverID: "s", userID: "b")] = "lib-b"
                external?.set(stored, forKey: AppSettings.Key.lastLibraryIDs.rawValue)
            }
            #expect(settings.lastLibraryID(serverID: "s", userID: "b") == nil)  // reload still pending
            settings.setLastLibraryID("lib-c", serverID: "s", userID: "c")

            #expect(settings.lastLibraryID(serverID: "s", userID: "b") == "lib-b")
            let stored = AppSettings.snapshot(from: defaults)
            #expect(stored.lastLibraryID(serverID: "s", userID: "a") == "lib-a")
            #expect(stored.lastLibraryID(serverID: "s", userID: "b") == "lib-b")
            #expect(stored.lastLibraryID(serverID: "s", userID: "c") == "lib-c")
            #expect(await eventually { settings.lastLibraryIDs == stored.lastLibraryIDs })
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

    @Test func removeAccountDataClearsOnlyThatAccountsEntries() async throws {
        try await withIsolatedDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            // The removed account, the same server with another user, the same user on another
            // server, and a user whose ID only starts with the removed one's.
            let accounts = [("s", "u"), ("s", "other"), ("t", "u"), ("s", "uu")]
            for (server, user) in accounts {
                settings.setLastLibraryID("lib-\(server)-\(user)", serverID: server, userID: user)
                settings.setLibraryViewPreferencesJSON("{}", serverID: server, userID: user, libraryID: "lib-1")
                settings.setRecentSearchesJSON("[\"Dune\"]", serverID: server, userID: user, libraryID: "lib-1")
                settings.setRecentSearchesJSON("[\"Emma\"]", serverID: server, userID: user, libraryID: "lib-2")
            }

            settings.removeAccountData(serverID: "s", userID: "u")
            for reader in [settings, AppSettings(defaults: defaults)] {
                #expect(reader.lastLibraryID(serverID: "s", userID: "u") == nil)
                #expect(reader.libraryViewPreferencesJSON(serverID: "s", userID: "u", libraryID: "lib-1") == nil)
                #expect(reader.recentSearchesJSON(serverID: "s", userID: "u", libraryID: "lib-1") == nil)
                #expect(reader.recentSearchesJSON(serverID: "s", userID: "u", libraryID: "lib-2") == nil)
                for (server, user) in accounts.dropFirst() {
                    #expect(reader.lastLibraryID(serverID: server, userID: user) == "lib-\(server)-\(user)")
                    #expect(
                        reader.libraryViewPreferencesJSON(serverID: server, userID: user, libraryID: "lib-1") == "{}")
                    #expect(
                        reader.recentSearchesJSON(serverID: server, userID: user, libraryID: "lib-2") == "[\"Emma\"]")
                }
            }
            #expect(settings.lastLibraryIDs.count == 3 && settings.recentSearches.count == 6)
        }
    }

    @Test func removeAccountDataKeepsPrefixedAccounts() async throws {
        try await withIsolatedDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            settings.setLastLibraryID("lib-b", serverID: "a", userID: "b")
            settings.setLastLibraryID("lib-bc", serverID: "a", userID: "bc")
            settings.setRecentSearchesJSON("[\"Dune\"]", serverID: "a", userID: "bc", libraryID: "lib")

            // `a|b` mustn't match `a|bc`.
            settings.removeAccountData(serverID: "a", userID: "b")
            #expect(settings.lastLibraryIDs == [AppSettings.accountKey(serverID: "a", userID: "bc"): "lib-bc"])
            #expect(settings.recentSearchesJSON(serverID: "a", userID: "bc", libraryID: "lib") == "[\"Dune\"]")
        }
    }

    @Test func removeAccountDataKeepingOnlyListedAccountsKeepsTheirEntries() async throws {
        try await withIsolatedDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            for (server, user) in [("s", "u"), ("s", "uu"), ("s", "other"), ("t", "u")] {
                settings.setLastLibraryID("lib", serverID: server, userID: user)
                settings.setRecentSearchesJSON("[\"Dune\"]", serverID: server, userID: user, libraryID: "lib")
            }

            // `s|u` keeps its own entries, not `s|uu`'s.
            settings.removeAccountData(keepingOnly: [(serverID: "s", userID: "u"), (serverID: "t", userID: "u")])
            for reader in [settings, AppSettings(defaults: defaults)] {
                #expect(Set(reader.lastLibraryIDs.keys) == ["s|u", "t|u"])
                #expect(Set(reader.recentSearches.keys) == ["s|u|lib", "t|u|lib"])
            }

            settings.removeAccountData(keepingOnly: [])
            #expect(settings.lastLibraryIDs.isEmpty && settings.recentSearches.isEmpty)
        }
    }

    @Test func removeAccountDataWritesNothingWhenTheresNothingToRemove() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            AppSettings(defaults: defaults).removeAccountData(serverID: "s", userID: "u")
            AppSettings(defaults: defaults).removeAccountData(keepingOnly: [])
            #expect(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
        }
    }

    @Test func fallsBackToStandardDefaultsWithoutAppGroup() {
        let defaults = AppSettings.sharedDefaults(appGroupIdentifier: "group.test.unavailable") { _ in false }
        #expect(defaults === UserDefaults.standard)
    }

    @Test func usesTheAppGroupSuiteWhenAvailable() {
        // A non-`group.` suite name, so the test doesn't create an App Group preferences file.
        let identifier = "ABSCoreTests.AppGroupStandIn.\(UUID().uuidString)"
        let defaults = AppSettings.sharedDefaults(appGroupIdentifier: identifier) { $0 == identifier }
        defer { defaults.removePersistentDomain(forName: identifier) }
        #expect(defaults !== UserDefaults.standard)
        defaults.set(true, forKey: AppSettings.Key.autoSleepTimer.rawValue)
        #expect(UserDefaults(suiteName: identifier)?.bool(forKey: AppSettings.Key.autoSleepTimer.rawValue) == true)
        #expect(UserDefaults.standard.object(forKey: AppSettings.Key.autoSleepTimer.rawValue) == nil)
    }

    @Test func invalidAssignmentsAreRejected() async throws {
        try await withIsolatedDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)
            settings.jumpForwardTime = 30
            settings.jumpForwardTime = 0
            settings.jumpBackwardsTime = -5
            settings.sleepTimerLength = -1
            settings.autoSleepTimerAutoRewindTime = -1
            settings.playbackRate = 0
            settings.playbackRate = .nan
            settings.autoSleepTimerStartTime = "25:00"
            settings.autoSleepTimerEndTime = "6:00"

            func stored(_ key: AppSettings.Key) -> Any? { defaults.object(forKey: key.rawValue) }
            #expect(settings.jumpForwardTime == 30)
            #expect(stored(.jumpForwardTime) as? Int == 30)
            #expect(settings.jumpBackwardsTime == 10)
            #expect(stored(.jumpBackwardsTime) == nil)
            #expect(settings.sleepTimerLength == 900_000)
            #expect(stored(.sleepTimerLength) == nil)
            #expect(settings.autoSleepTimerAutoRewindTime == 300_000)
            #expect(stored(.autoSleepTimerAutoRewindTime) == nil)
            #expect(settings.playbackRate == 1.0)
            #expect(stored(.playbackRate) == nil)
            #expect(settings.autoSleepTimerStartTime == "22:00")
            #expect(stored(.autoSleepTimerStartTime) == nil)
            #expect(settings.autoSleepTimerEndTime == "06:00")
            #expect(stored(.autoSleepTimerEndTime) == nil)
            #expect(AppSettings(defaults: defaults).jumpForwardTime == settings.jumpForwardTime)
        }
    }

    @Test func storeDeallocatesAndLaterWritesAreSafe() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            weak var weakSettings: AppSettings?
            do {
                let settings = AppSettings(defaults: defaults)
                weakSettings = settings
                settings.jumpForwardTime = 15
            }
            #expect(weakSettings == nil)

            UserDefaults(suiteName: suiteName)?.set(45, forKey: AppSettings.Key.jumpForwardTime.rawValue)
            await Task.detached {
                for value in 1...20 {
                    UserDefaults(suiteName: suiteName)?.set(value, forKey: AppSettings.Key.jumpBackwardsTime.rawValue)
                }
            }.value
            try await Task.sleep(for: .milliseconds(50))
            #expect(AppSettings(defaults: defaults).jumpForwardTime == 45)
        }
    }

    @Test func burstOfBackgroundWritesEndsAtTheLastValue() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            let settings = AppSettings(defaults: defaults)
            await Task.detached {
                let external = UserDefaults(suiteName: suiteName)
                for value in 1...100 {
                    external?.set(value, forKey: AppSettings.Key.jumpBackwardsTime.rawValue)
                }
            }.value
            #expect(await eventually { settings.jumpBackwardsTime == 100 })
        }
    }

    @Test func snapshotReadsValidatedValuesOffTheMainActor() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            let settings = AppSettings(defaults: defaults)
            settings.theme = .dark
            settings.playbackRate = 1.5
            settings.setLastLibraryID("lib-1", serverID: "s", userID: "u")
            defaults.set(-3, forKey: AppSettings.Key.jumpForwardTime.rawValue)

            let snapshot = await Task.detached { () -> AppSettings.Snapshot? in
                guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
                return AppSettings.snapshot(from: defaults)
            }.value
            let values = try #require(snapshot)
            #expect(values.theme == .dark)
            #expect(values.playbackRate == 1.5)
            #expect(values.jumpForwardTime == 10)
            #expect(values.chapterTrack == true)
            #expect(values.lastLibraryID(serverID: "s", userID: "u") == "lib-1")
            #expect(values.jumpForwardTime == settings.jumpForwardTime)
        }
    }

    @Test func resetRemovesStoredValues() async throws {
        try await withIsolatedDefaults { defaults, suiteName in
            let settings = AppSettings(defaults: defaults)
            settings.theme = .black
            settings.jumpForwardTime = 60
            settings.setLastLibraryID("lib", serverID: "s", userID: "u")

            settings.reset(.theme)
            #expect(settings.theme == .system)
            #expect(defaults.object(forKey: AppSettings.Key.theme.rawValue) == nil)
            #expect(settings.jumpForwardTime == 60)

            settings.resetAll()
            #expect(settings.jumpForwardTime == 10)
            #expect(settings.lastLibraryIDs.isEmpty)
            #expect(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
        }
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

    @Test(arguments: [("00:00", 0), ("06:00", 360), ("22:30", 1350), ("23:59", 1439)])
    func parsesMinutesSinceMidnight(_ value: String, _ minutes: Int) {
        #expect(AppSettings.minutesSinceMidnight(value) == minutes)
    }

    @Test(arguments: [
        "24:00", "12:60", "6:00", "12:5", "ab:cd", "1200", "12:00:00", "", "+1:00", "-0:30", "00:+1", "１２:００",
        "٠٧:٠٠",
    ])
    func rejectsInvalidTimesOfDay(_ value: String) {
        #expect(!AppSettings.isTimeOfDay(value))
        #expect(AppSettings.minutesSinceMidnight(value) == nil)
    }
}
