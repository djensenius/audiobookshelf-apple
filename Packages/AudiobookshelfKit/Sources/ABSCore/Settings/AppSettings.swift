import Foundation
import Observation

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
/// suite, `@AppStorage`) are picked up through key-value observing and republished
/// through Observation.
///
/// Missing or invalid stored values (wrong type, out of range, unknown enum case) read
/// as the default. Defaults are never written back, so the store only contains values
/// the user changed.
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
    public var jumpForwardTime = Default.jumpForwardTime { didSet { persist(.jumpForwardTime, jumpForwardTime) } }
    /// Seconds. Must be positive.
    public var jumpBackwardsTime = Default.jumpBackwardsTime {
        didSet { persist(.jumpBackwardsTime, jumpBackwardsTime) }
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
        didSet { persist(.sleepTimerLength, sleepTimerLength) }
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
        didSet { persist(.autoSleepTimerStartTime, autoSleepTimerStartTime) }
    }
    /// 24-hour `HH:mm`.
    public var autoSleepTimerEndTime = Default.autoSleepTimerEndTime {
        didSet { persist(.autoSleepTimerEndTime, autoSleepTimerEndTime) }
    }
    public var autoSleepTimerAutoRewind = Default.autoSleepTimerAutoRewind {
        didSet { persist(.autoSleepTimerAutoRewind, autoSleepTimerAutoRewind) }
    }
    /// Milliseconds.
    public var autoSleepTimerAutoRewindTime = Default.autoSleepTimerAutoRewindTime {
        didSet { persist(.autoSleepTimerAutoRewindTime, autoSleepTimerAutoRewindTime) }
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
    public var playbackRate = Default.playbackRate { didSet { persist(.playbackRate, playbackRate) } }
    public var chapterTrack = Default.chapterTrack { didSet { persist(.chapterTrack, chapterTrack) } }

    // MARK: Navigation

    /// Last-used library per server and user; see ``lastLibraryID(serverID:userID:)``.
    public private(set) var lastLibraryIDs: [String: String] = [:] {
        didSet { persist(.lastLibraryIDs, lastLibraryIDs) }
    }

    @ObservationIgnored private var isReloading = false
    @ObservationIgnored private var observer: DefaultsObserver?

    /// Creates settings backed by `defaults`, by default the App Group store (or the
    /// app's own store when the App Group is unavailable).
    public init(defaults: UserDefaults = AppSettings.sharedDefaults()) {
        self.defaults = defaults
        reloadFromStore()
        observer = DefaultsObserver(defaults: defaults, keys: Key.allCases.map(\.rawValue)) { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.reloadFromStore() }
            } else {
                Task { @MainActor in self?.reloadFromStore() }
            }
        }
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
    public func setLastLibraryID(_ libraryID: String?, serverID: String, userID: String) {
        lastLibraryIDs[Self.accountKey(serverID: serverID, userID: userID)] = libraryID
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
            // when the process isn't entitled, so check the entitlement itself.
            guard let task = SecTaskCreateFromSelf(nil),
                let groups = SecTaskCopyValueForEntitlement(
                    task, "com.apple.security.application-groups" as CFString, nil) as? [String]
            else { return false }
            return groups.contains(identifier)
        #else
            return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
        #endif
    }

    // MARK: Reading and writing

    private func persist(_ key: Key, _ value: Any) {
        guard !isReloading else { return }
        defaults.set(value, forKey: key.rawValue)
    }

    /// Re-reads every key and assigns only the values that changed, so observers of
    /// unchanged settings aren't notified.
    private func reloadFromStore() {
        isReloading = true
        defer { isReloading = false }
        let store = Reader(defaults: defaults)
        update(\.enableAltView, store.bool(.enableAltView, Default.enableAltView))
        update(\.theme, store.enumValue(.theme, Default.theme))
        update(\.hapticFeedback, store.enumValue(.hapticFeedback, Default.hapticFeedback))
        update(\.jumpForwardTime, store.int(.jumpForwardTime, Default.jumpForwardTime) { $0 > 0 })
        update(\.jumpBackwardsTime, store.int(.jumpBackwardsTime, Default.jumpBackwardsTime) { $0 > 0 })
        update(\.disableAutoRewind, store.bool(.disableAutoRewind, Default.disableAutoRewind))
        update(\.enableMp3IndexSeeking, store.bool(.enableMp3IndexSeeking, Default.enableMp3IndexSeeking))
        update(
            \.allowSeekingOnMediaControls,
            store.bool(.allowSeekingOnMediaControls, Default.allowSeekingOnMediaControls))
        update(\.sleepTimerLength, store.int(.sleepTimerLength, Default.sleepTimerLength) { $0 >= 0 })
        update(
            \.disableShakeToResetSleepTimer,
            store.bool(.disableShakeToResetSleepTimer, Default.disableShakeToResetSleepTimer))
        update(\.shakeSensitivity, store.enumValue(.shakeSensitivity, Default.shakeSensitivity))
        update(\.disableSleepTimerFadeOut, store.bool(.disableSleepTimerFadeOut, Default.disableSleepTimerFadeOut))
        update(
            \.disableSleepTimerResetFeedback,
            store.bool(.disableSleepTimerResetFeedback, Default.disableSleepTimerResetFeedback))
        update(
            \.enableSleepTimerAlmostDoneChime,
            store.bool(.enableSleepTimerAlmostDoneChime, Default.enableSleepTimerAlmostDoneChime))
        update(\.autoSleepTimer, store.bool(.autoSleepTimer, Default.autoSleepTimer))
        update(
            \.autoSleepTimerStartTime,
            store.string(.autoSleepTimerStartTime, Default.autoSleepTimerStartTime, where: Self.isTimeOfDay))
        update(
            \.autoSleepTimerEndTime,
            store.string(.autoSleepTimerEndTime, Default.autoSleepTimerEndTime, where: Self.isTimeOfDay))
        update(\.autoSleepTimerAutoRewind, store.bool(.autoSleepTimerAutoRewind, Default.autoSleepTimerAutoRewind))
        update(
            \.autoSleepTimerAutoRewindTime,
            store.int(.autoSleepTimerAutoRewindTime, Default.autoSleepTimerAutoRewindTime) { $0 >= 0 })
        update(\.downloadUsingCellular, store.enumValue(.downloadUsingCellular, Default.downloadUsingCellular))
        update(\.streamingUsingCellular, store.enumValue(.streamingUsingCellular, Default.streamingUsingCellular))
        update(\.playbackRate, store.double(.playbackRate, Default.playbackRate) { $0.isFinite && $0 > 0 })
        update(\.chapterTrack, store.bool(.chapterTrack, Default.chapterTrack))
        update(\.lastLibraryIDs, store.stringDictionary(.lastLibraryIDs))
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    /// Accepts `HH:mm` with hours 00–23 and minutes 00–59.
    nonisolated static func isTimeOfDay(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isASCII) }),
            let hours = Int(parts[0]), let minutes = Int(parts[1])
        else { return false }
        return (0..<24).contains(hours) && (0..<60).contains(minutes)
    }
}

/// Typed, validating reads from `UserDefaults`; anything unusable reads as the default.
private struct Reader {
    let defaults: UserDefaults

    func bool(_ key: AppSettings.Key, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    func int(_ key: AppSettings.Key, _ fallback: Int, where isValid: (Int) -> Bool) -> Int {
        guard let value = defaults.object(forKey: key.rawValue) as? Int, isValid(value) else { return fallback }
        return value
    }

    func double(_ key: AppSettings.Key, _ fallback: Double, where isValid: (Double) -> Bool) -> Double {
        guard let value = defaults.object(forKey: key.rawValue) as? Double, isValid(value) else { return fallback }
        return value
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

/// Key-value observes `UserDefaults` keys, which reports writes from any `UserDefaults`
/// instance for the same suite (including `@AppStorage`).
///
/// `@unchecked Sendable`: every stored property is immutable after `init`, and
/// `UserDefaults` KVO registration and removal are thread-safe.
private final class DefaultsObserver: NSObject, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keys: [String]
    private let onChange: @Sendable () -> Void

    init(defaults: UserDefaults, keys: [String], onChange: @escaping @Sendable () -> Void) {
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
        onChange()
    }
}
