import Foundation
import Observation
import Synchronization

#if os(macOS)
    import Security
#endif

/// Device and player settings, stored in the App Group `UserDefaults`.
///
/// Every setting is a property-list value (`Bool`, `Int`, `Double`, `String`, or a
/// `String`-backed enum stored as its raw value) under a stable ``Key``, so SwiftUI
/// views, widgets and other scenes can also bind to it with
/// `@AppStorage(AppSettings.Key.<name>.rawValue, store: settings.defaults)`.
/// Writes from anywhere in the process (another `UserDefaults` instance for the same
/// suite, `@AppStorage`) and, for the App Group suite, from other processes such as
/// widgets are picked up through key-value observing and republished through
/// Observation. ``lastLibraryIDs`` is a dictionary and can't be bound with
/// `@AppStorage`. Code off the main actor reads validated values with
/// ``snapshot(from:)``.
///
/// Missing or invalid stored values (wrong type, out of range, unknown enum case) read
/// as the default, and invalid values assigned to a property are rejected (the property
/// keeps its previous value and nothing is written). Defaults are never written back, so
/// the store only contains values the user changed.
///
/// Names, units and defaults follow the legacy app (`pages/settings.vue`,
/// `DeviceSettings.swift`, `PlayerSettings.swift`). Dropped legacy settings:
/// `lockOrientation` (the native app follows the system's orientation and
/// multitasking behaviour), `languageCode` (the system's per-app language is used) and
/// the Android Auto options (no Android app).
@MainActor
@Observable
public final class AppSettings {
    /// The App Group shared by the app and its extensions (ADR 0002).
    public nonisolated static let appGroupIdentifier = "group.org.davidjensenius.Audiobookshelf"

    /// Stable `UserDefaults` keys. Keys contain no dots, so key-value observing and
    /// `@AppStorage` treat each one as a single key.
    public enum Key: String, CaseIterable, Sendable {
        case enableAltView = "settings_enableAltView"
        case theme = "settings_theme"
        case hapticFeedback = "settings_hapticFeedback"
        case jumpForwardTime = "settings_jumpForwardTime"
        case jumpBackwardsTime = "settings_jumpBackwardsTime"
        case disableAutoRewind = "settings_disableAutoRewind"
        case enableMp3IndexSeeking = "settings_enableMp3IndexSeeking"
        case allowSeekingOnMediaControls = "settings_allowSeekingOnMediaControls"
        case sleepTimerLength = "settings_sleepTimerLength"
        case disableShakeToResetSleepTimer = "settings_disableShakeToResetSleepTimer"
        case shakeSensitivity = "settings_shakeSensitivity"
        case disableSleepTimerFadeOut = "settings_disableSleepTimerFadeOut"
        case disableSleepTimerResetFeedback = "settings_disableSleepTimerResetFeedback"
        case enableSleepTimerAlmostDoneChime = "settings_enableSleepTimerAlmostDoneChime"
        case autoSleepTimer = "settings_autoSleepTimer"
        case autoSleepTimerStartTime = "settings_autoSleepTimerStartTime"
        case autoSleepTimerEndTime = "settings_autoSleepTimerEndTime"
        case autoSleepTimerAutoRewind = "settings_autoSleepTimerAutoRewind"
        case autoSleepTimerAutoRewindTime = "settings_autoSleepTimerAutoRewindTime"
        case downloadUsingCellular = "settings_downloadUsingCellular"
        case streamingUsingCellular = "settings_streamingUsingCellular"
        case playbackRate = "settings_playbackRate"
        case chapterTrack = "settings_chapterTrack"
        /// A `[String: String]` dictionary from ``AppSettings/accountKey(serverID:userID:)``
        /// to library ID.
        case lastLibraryIDs = "settings_lastLibraryIDs"
    }

    /// Default values, for `@AppStorage` declarations that need one.
    public enum Default {
        public static let enableAltView = true
        public static let theme = AppTheme.system
        public static let hapticFeedback = HapticFeedback.light
        public static let jumpForwardTime = 10
        public static let jumpBackwardsTime = 10
        public static let disableAutoRewind = false
        public static let enableMp3IndexSeeking = false
        public static let allowSeekingOnMediaControls = false
        public static let sleepTimerLength = 900_000
        public static let disableShakeToResetSleepTimer = false
        public static let shakeSensitivity = ShakeSensitivity.medium
        public static let disableSleepTimerFadeOut = false
        public static let disableSleepTimerResetFeedback = false
        public static let enableSleepTimerAlmostDoneChime = false
        public static let autoSleepTimer = false
        public static let autoSleepTimerStartTime = "22:00"
        public static let autoSleepTimerEndTime = "06:00"
        public static let autoSleepTimerAutoRewind = false
        public static let autoSleepTimerAutoRewindTime = 300_000
        public static let downloadUsingCellular = CellularPolicy.always
        public static let streamingUsingCellular = CellularPolicy.always
        public static let playbackRate = 1.0
        public static let chapterTrack = true
    }

    /// The store the settings read from and write to.
    public let defaults: UserDefaults

    // MARK: Display

    public var enableAltView = Default.enableAltView { didSet { persist(.enableAltView, enableAltView) } }
    public var theme = Default.theme { didSet { persist(.theme, theme.rawValue) } }
    public var hapticFeedback = Default.hapticFeedback {
        didSet { persist(.hapticFeedback, hapticFeedback.rawValue) }
    }

    // MARK: Playback

    /// Seconds. Must be positive.
    public var jumpForwardTime = Default.jumpForwardTime {
        didSet { persist(.jumpForwardTime, \.jumpForwardTime, oldValue, isValid: Self.isJumpInterval) }
    }
    /// Seconds. Must be positive.
    public var jumpBackwardsTime = Default.jumpBackwardsTime {
        didSet { persist(.jumpBackwardsTime, \.jumpBackwardsTime, oldValue, isValid: Self.isJumpInterval) }
    }
    public var disableAutoRewind = Default.disableAutoRewind {
        didSet { persist(.disableAutoRewind, disableAutoRewind) }
    }
    public var enableMp3IndexSeeking = Default.enableMp3IndexSeeking {
        didSet { persist(.enableMp3IndexSeeking, enableMp3IndexSeeking) }
    }
    public var allowSeekingOnMediaControls = Default.allowSeekingOnMediaControls {
        didSet { persist(.allowSeekingOnMediaControls, allowSeekingOnMediaControls) }
    }

    // MARK: Sleep timer

    /// Milliseconds; `0` means "end of chapter" (legacy).
    public var sleepTimerLength = Default.sleepTimerLength {
        didSet { persist(.sleepTimerLength, \.sleepTimerLength, oldValue, isValid: Self.isDuration) }
    }
    public var disableShakeToResetSleepTimer = Default.disableShakeToResetSleepTimer {
        didSet { persist(.disableShakeToResetSleepTimer, disableShakeToResetSleepTimer) }
    }
    public var shakeSensitivity = Default.shakeSensitivity {
        didSet { persist(.shakeSensitivity, shakeSensitivity.rawValue) }
    }
    public var disableSleepTimerFadeOut = Default.disableSleepTimerFadeOut {
        didSet { persist(.disableSleepTimerFadeOut, disableSleepTimerFadeOut) }
    }
    public var disableSleepTimerResetFeedback = Default.disableSleepTimerResetFeedback {
        didSet { persist(.disableSleepTimerResetFeedback, disableSleepTimerResetFeedback) }
    }
    public var enableSleepTimerAlmostDoneChime = Default.enableSleepTimerAlmostDoneChime {
        didSet { persist(.enableSleepTimerAlmostDoneChime, enableSleepTimerAlmostDoneChime) }
    }
    public var autoSleepTimer = Default.autoSleepTimer { didSet { persist(.autoSleepTimer, autoSleepTimer) } }
    /// 24-hour `HH:mm`.
    public var autoSleepTimerStartTime = Default.autoSleepTimerStartTime {
        didSet { persist(.autoSleepTimerStartTime, \.autoSleepTimerStartTime, oldValue, isValid: Self.isTimeOfDay) }
    }
    /// 24-hour `HH:mm`.
    public var autoSleepTimerEndTime = Default.autoSleepTimerEndTime {
        didSet { persist(.autoSleepTimerEndTime, \.autoSleepTimerEndTime, oldValue, isValid: Self.isTimeOfDay) }
    }
    public var autoSleepTimerAutoRewind = Default.autoSleepTimerAutoRewind {
        didSet { persist(.autoSleepTimerAutoRewind, autoSleepTimerAutoRewind) }
    }
    /// Milliseconds.
    public var autoSleepTimerAutoRewindTime = Default.autoSleepTimerAutoRewindTime {
        didSet {
            persist(.autoSleepTimerAutoRewindTime, \.autoSleepTimerAutoRewindTime, oldValue, isValid: Self.isDuration)
        }
    }

    // MARK: Data

    public var downloadUsingCellular = Default.downloadUsingCellular {
        didSet { persist(.downloadUsingCellular, downloadUsingCellular.rawValue) }
    }
    public var streamingUsingCellular = Default.streamingUsingCellular {
        didSet { persist(.streamingUsingCellular, streamingUsingCellular.rawValue) }
    }

    // MARK: Player

    /// Must be positive.
    public var playbackRate = Default.playbackRate {
        didSet { persist(.playbackRate, \.playbackRate, oldValue, isValid: Self.isPlaybackRate) }
    }
    public var chapterTrack = Default.chapterTrack { didSet { persist(.chapterTrack, chapterTrack) } }

    // MARK: Navigation

    /// Last-used library per server and user; see ``lastLibraryID(serverID:userID:)``.
    ///
    /// Stored as a `[String: String]` dictionary, which `@AppStorage` can't bind to; use
    /// this store or ``Snapshot`` to read it.
    public private(set) var lastLibraryIDs: [String: String] = [:] {
        didSet { persist(.lastLibraryIDs, lastLibraryIDs) }
    }

    @ObservationIgnored private var isReloading = false
    @ObservationIgnored private var observer: DefaultsObserver?

    /// Creates settings backed by `defaults`, by default the App Group store (or the
    /// app's own store when the App Group is unavailable).
    public init(defaults: UserDefaults = AppSettings.sharedDefaults()) {
        self.defaults = defaults
        // Observe before the first read so a write between reading a key and observing it
        // isn't missed.
        observer = DefaultsObserver(defaults: defaults, keys: Key.allCases.map(\.rawValue)) { [weak self] in
            self?.reloadFromStore()
        }
        reloadFromStore()
    }

    // MARK: Reset

    /// Removes the stored value so the default applies again.
    public func reset(_ key: Key) {
        defaults.removeObject(forKey: key.rawValue)
        reloadFromStore()
    }

    /// Removes every stored setting, including the last-used libraries.
    public func resetAll() {
        for key in Key.allCases {
            defaults.removeObject(forKey: key.rawValue)
        }
        reloadFromStore()
    }

    // MARK: Last-used library

    /// The key under which the last-used library of a server and user is stored.
    public nonisolated static func accountKey(serverID: String, userID: String) -> String {
        "\(serverID)|\(userID)"
    }

    public func lastLibraryID(serverID: String, userID: String) -> String? {
        lastLibraryIDs[Self.accountKey(serverID: serverID, userID: userID)]
    }

    /// Saves the last-used library for a server and user; `nil` removes it.
    ///
    /// Applies the change to the dictionary currently in the store, not the cached copy,
    /// so another account's entry written elsewhere (whose reload may still be pending)
    /// isn't overwritten.
    public func setLastLibraryID(_ libraryID: String?, serverID: String, userID: String) {
        var stored = Reader(defaults: defaults).stringDictionary(.lastLibraryIDs)
        stored[Self.accountKey(serverID: serverID, userID: userID)] = libraryID
        lastLibraryIDs = stored
    }

    // MARK: Store selection

    /// The App Group `UserDefaults`, or `.standard` when the App Group container is
    /// unavailable (for example, the ad hoc signed macOS test host has no App Group
    /// entitlement; ADR 0002).
    public nonisolated static func sharedDefaults(
        appGroupIdentifier: String = AppSettings.appGroupIdentifier,
        isAppGroupAvailable: (String) -> Bool = AppSettings.isAppGroupAvailable
    ) -> UserDefaults {
        guard isAppGroupAvailable(appGroupIdentifier), let suite = UserDefaults(suiteName: appGroupIdentifier) else {
            return .standard
        }
        return suite
    }

    /// Whether this process may use the App Group container.
    public nonisolated static func isAppGroupAvailable(_ identifier: String) -> Bool {
        #if os(macOS)
            // On macOS `containerURL(forSecurityApplicationGroupIdentifier:)` returns a URL even
            // when the process isn't entitled, so check the entitlement itself. This is a
            // best-effort check: on macOS 15 and later, an App Group entitlement that no
            // provisioning profile authorises may still be denied at runtime.
            guard let task = SecTaskCreateFromSelf(nil),
                let groups = SecTaskCopyValueForEntitlement(
                    task, "com.apple.security.application-groups" as CFString, nil) as? [String]
            else { return false }
            return groups.contains(identifier)
        #else
            return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
        #endif
    }

    // MARK: Validation

    /// Jump intervals are positive seconds.
    nonisolated static func isJumpInterval(_ value: Int) -> Bool { value > 0 }

    /// Durations are non-negative milliseconds.
    nonisolated static func isDuration(_ value: Int) -> Bool { value >= 0 }

    nonisolated static func isPlaybackRate(_ value: Double) -> Bool { value.isFinite && value > 0 }

    /// Accepts `HH:mm` (exactly two ASCII digits each) with hours 00–23 and minutes 00–59.
    nonisolated static func isTimeOfDay(_ value: String) -> Bool { minutesSinceMidnight(value) != nil }

    /// The minutes since midnight of a 24-hour `HH:mm` time (as stored in
    /// ``autoSleepTimerStartTime`` and ``autoSleepTimerEndTime``), or `nil` if it isn't valid.
    public nonisolated static func minutesSinceMidnight(_ timeOfDay: String) -> Int? {
        let parts = timeOfDay.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
            parts.allSatisfy({
                $0.utf8.count == 2 && $0.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
            }),
            let hours = Int(parts[0]), let minutes = Int(parts[1]),
            (0..<24).contains(hours), (0..<60).contains(minutes)
        else { return nil }
        return hours * 60 + minutes
    }

    // MARK: Reading and writing

    private func persist(_ key: Key, _ value: Any) {
        guard !isReloading else { return }
        defaults.set(value, forKey: key.rawValue)
    }

    /// Persists a validated setting. An invalid value is never written; the property goes
    /// back to its previous value, which is always valid.
    private func persist<Value>(
        _ key: Key, _ keyPath: ReferenceWritableKeyPath<AppSettings, Value>, _ oldValue: Value,
        isValid: (Value) -> Bool
    ) {
        let value = self[keyPath: keyPath]
        guard isValid(value) else {
            let wasReloading = isReloading
            isReloading = true
            defer { isReloading = wasReloading }
            self[keyPath: keyPath] = oldValue
            return
        }
        persist(key, value)
    }

    /// Re-reads every key and assigns only the values that changed, so observers of
    /// unchanged settings aren't notified.
    private func reloadFromStore() {
        isReloading = true
        defer { isReloading = false }
        let snapshot = Snapshot(defaults: defaults)
        update(\.enableAltView, snapshot.enableAltView)
        update(\.theme, snapshot.theme)
        update(\.hapticFeedback, snapshot.hapticFeedback)
        update(\.jumpForwardTime, snapshot.jumpForwardTime)
        update(\.jumpBackwardsTime, snapshot.jumpBackwardsTime)
        update(\.disableAutoRewind, snapshot.disableAutoRewind)
        update(\.enableMp3IndexSeeking, snapshot.enableMp3IndexSeeking)
        update(\.allowSeekingOnMediaControls, snapshot.allowSeekingOnMediaControls)
        update(\.sleepTimerLength, snapshot.sleepTimerLength)
        update(\.disableShakeToResetSleepTimer, snapshot.disableShakeToResetSleepTimer)
        update(\.shakeSensitivity, snapshot.shakeSensitivity)
        update(\.disableSleepTimerFadeOut, snapshot.disableSleepTimerFadeOut)
        update(\.disableSleepTimerResetFeedback, snapshot.disableSleepTimerResetFeedback)
        update(\.enableSleepTimerAlmostDoneChime, snapshot.enableSleepTimerAlmostDoneChime)
        update(\.autoSleepTimer, snapshot.autoSleepTimer)
        update(\.autoSleepTimerStartTime, snapshot.autoSleepTimerStartTime)
        update(\.autoSleepTimerEndTime, snapshot.autoSleepTimerEndTime)
        update(\.autoSleepTimerAutoRewind, snapshot.autoSleepTimerAutoRewind)
        update(\.autoSleepTimerAutoRewindTime, snapshot.autoSleepTimerAutoRewindTime)
        update(\.downloadUsingCellular, snapshot.downloadUsingCellular)
        update(\.streamingUsingCellular, snapshot.streamingUsingCellular)
        update(\.playbackRate, snapshot.playbackRate)
        update(\.chapterTrack, snapshot.chapterTrack)
        update(\.lastLibraryIDs, snapshot.lastLibraryIDs)
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}

// MARK: - Snapshot

extension AppSettings {
    /// A validated, read-only copy of the stored settings for code that isn't on the main
    /// actor, such as widgets and App Intents. Uses the same defaults and validation as
    /// ``AppSettings``.
    public struct Snapshot: Sendable, Equatable {
        public let enableAltView: Bool
        public let theme: AppTheme
        public let hapticFeedback: HapticFeedback
        public let jumpForwardTime: Int
        public let jumpBackwardsTime: Int
        public let disableAutoRewind: Bool
        public let enableMp3IndexSeeking: Bool
        public let allowSeekingOnMediaControls: Bool
        public let sleepTimerLength: Int
        public let disableShakeToResetSleepTimer: Bool
        public let shakeSensitivity: ShakeSensitivity
        public let disableSleepTimerFadeOut: Bool
        public let disableSleepTimerResetFeedback: Bool
        public let enableSleepTimerAlmostDoneChime: Bool
        public let autoSleepTimer: Bool
        public let autoSleepTimerStartTime: String
        public let autoSleepTimerEndTime: String
        public let autoSleepTimerAutoRewind: Bool
        public let autoSleepTimerAutoRewindTime: Int
        public let downloadUsingCellular: CellularPolicy
        public let streamingUsingCellular: CellularPolicy
        public let playbackRate: Double
        public let chapterTrack: Bool
        public let lastLibraryIDs: [String: String]

        init(defaults: UserDefaults) {
            let store = Reader(defaults: defaults)
            enableAltView = store.bool(.enableAltView, Default.enableAltView)
            theme = store.enumValue(.theme, Default.theme)
            hapticFeedback = store.enumValue(.hapticFeedback, Default.hapticFeedback)
            jumpForwardTime = store.int(.jumpForwardTime, Default.jumpForwardTime, where: isJumpInterval)
            jumpBackwardsTime = store.int(.jumpBackwardsTime, Default.jumpBackwardsTime, where: isJumpInterval)
            disableAutoRewind = store.bool(.disableAutoRewind, Default.disableAutoRewind)
            enableMp3IndexSeeking = store.bool(.enableMp3IndexSeeking, Default.enableMp3IndexSeeking)
            allowSeekingOnMediaControls = store.bool(
                .allowSeekingOnMediaControls, Default.allowSeekingOnMediaControls)
            sleepTimerLength = store.int(.sleepTimerLength, Default.sleepTimerLength, where: isDuration)
            disableShakeToResetSleepTimer = store.bool(
                .disableShakeToResetSleepTimer, Default.disableShakeToResetSleepTimer)
            shakeSensitivity = store.enumValue(.shakeSensitivity, Default.shakeSensitivity)
            disableSleepTimerFadeOut = store.bool(.disableSleepTimerFadeOut, Default.disableSleepTimerFadeOut)
            disableSleepTimerResetFeedback = store.bool(
                .disableSleepTimerResetFeedback, Default.disableSleepTimerResetFeedback)
            enableSleepTimerAlmostDoneChime = store.bool(
                .enableSleepTimerAlmostDoneChime, Default.enableSleepTimerAlmostDoneChime)
            autoSleepTimer = store.bool(.autoSleepTimer, Default.autoSleepTimer)
            autoSleepTimerStartTime = store.string(
                .autoSleepTimerStartTime, Default.autoSleepTimerStartTime, where: isTimeOfDay)
            autoSleepTimerEndTime = store.string(
                .autoSleepTimerEndTime, Default.autoSleepTimerEndTime, where: isTimeOfDay)
            autoSleepTimerAutoRewind = store.bool(.autoSleepTimerAutoRewind, Default.autoSleepTimerAutoRewind)
            autoSleepTimerAutoRewindTime = store.int(
                .autoSleepTimerAutoRewindTime, Default.autoSleepTimerAutoRewindTime, where: isDuration)
            downloadUsingCellular = store.enumValue(.downloadUsingCellular, Default.downloadUsingCellular)
            streamingUsingCellular = store.enumValue(.streamingUsingCellular, Default.streamingUsingCellular)
            playbackRate = store.double(.playbackRate, Default.playbackRate, where: isPlaybackRate)
            chapterTrack = store.bool(.chapterTrack, Default.chapterTrack)
            lastLibraryIDs = store.stringDictionary(.lastLibraryIDs)
        }

        public func lastLibraryID(serverID: String, userID: String) -> String? {
            lastLibraryIDs[AppSettings.accountKey(serverID: serverID, userID: userID)]
        }
    }

    /// Reads a validated snapshot of the settings in `defaults`, by default the App Group
    /// store (or the app's own store when the App Group is unavailable). Safe off the main
    /// actor.
    public nonisolated static func snapshot(from defaults: UserDefaults = AppSettings.sharedDefaults()) -> Snapshot {
        Snapshot(defaults: defaults)
    }
}

/// Typed, validating reads from `UserDefaults`; anything unusable reads as the default.
///
/// `NSNumber` bridging would let `0`/`1` read as `Bool` and stored booleans read as
/// numbers, so booleans must be `CFBoolean` and numbers must not be.
private struct Reader {
    let defaults: UserDefaults

    func bool(_ key: AppSettings.Key, _ fallback: Bool) -> Bool {
        guard let object = defaults.object(forKey: key.rawValue), Self.isCFBoolean(object),
            let value = object as? Bool
        else { return fallback }
        return value
    }

    func int(_ key: AppSettings.Key, _ fallback: Int, where isValid: (Int) -> Bool) -> Int {
        guard let object = defaults.object(forKey: key.rawValue), !Self.isCFBoolean(object),
            let value = object as? Int, isValid(value)
        else { return fallback }
        return value
    }

    func double(_ key: AppSettings.Key, _ fallback: Double, where isValid: (Double) -> Bool) -> Double {
        guard let object = defaults.object(forKey: key.rawValue), !Self.isCFBoolean(object),
            let value = object as? Double, isValid(value)
        else { return fallback }
        return value
    }

    private static func isCFBoolean(_ object: Any) -> Bool {
        CFGetTypeID(object as CFTypeRef) == CFBooleanGetTypeID()
    }

    func string(_ key: AppSettings.Key, _ fallback: String, where isValid: (String) -> Bool) -> String {
        guard let value = defaults.object(forKey: key.rawValue) as? String, isValid(value) else { return fallback }
        return value
    }

    func enumValue<Value: RawRepresentable>(_ key: AppSettings.Key, _ fallback: Value) -> Value
    where Value.RawValue == String {
        guard let raw = defaults.object(forKey: key.rawValue) as? String else { return fallback }
        return Value(rawValue: raw) ?? fallback
    }

    func stringDictionary(_ key: AppSettings.Key) -> [String: String] {
        guard let dictionary = defaults.object(forKey: key.rawValue) as? [String: Any] else { return [:] }
        return dictionary.compactMapValues { $0 as? String }
    }
}

/// Key-value observes `UserDefaults` keys. KVO reports writes from any `UserDefaults`
/// instance for the same suite in this process (including `@AppStorage`) and, for the App
/// Group suite, writes from other processes such as widgets.
///
/// Notifications on the main thread run `onChange` synchronously. Notifications on other
/// threads are coalesced: a burst schedules a single main-actor `onChange`.
///
/// `@unchecked Sendable`: `defaults`, `keys` and `onChange` are immutable after `init`,
/// `pending` is a `Mutex`, and `UserDefaults` KVO registration and removal are thread-safe.
private final class DefaultsObserver: NSObject, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keys: [String]
    private let onChange: @MainActor @Sendable () -> Void
    private let pending = Mutex(false)

    init(defaults: UserDefaults, keys: [String], onChange: @escaping @MainActor @Sendable () -> Void) {
        self.defaults = defaults
        self.keys = keys
        self.onChange = onChange
        super.init()
        for key in keys {
            defaults.addObserver(self, forKeyPath: key, options: [], context: nil)
        }
    }

    deinit {
        for key in keys {
            defaults.removeObserver(self, forKeyPath: key)
        }
    }

    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { onChange() }
            return
        }
        let shouldSchedule = pending.withLock { isPending in
            defer { isPending = true }
            return !isPending
        }
        guard shouldSchedule else { return }
        Task { @MainActor in
            // Clear first so writes that land during the reload schedule another one.
            self.pending.withLock { $0 = false }
            self.onChange()
        }
    }
}
