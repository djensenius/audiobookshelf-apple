#if os(iOS)
    import AVFoundation
    import os

    private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "AudioSession")

    /// The parts of `AVAudioSession` the controller uses, so tests can pass a fake.
    public protocol AudioSessionProtocol: AnyObject {
        func setCategory(
            _ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
        ) throws
        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
    }

    extension AVAudioSession: AudioSessionProtocol {}

    /// Owns the iOS audio session for playback: `.playback` with `.spokenAudio`, activation around
    /// playback, deactivation on stop, and interruption and route-change handling through
    /// ``AudioInterruptionHandler``.
    ///
    /// Wiring: `let engine = AudioEngine(); let session = AudioSessionController(engine: engine);
    /// engine.audioSession = session`. The controller holds the engine weakly.
    @MainActor
    public final class AudioSessionController: AudioSessionActivating {
        public let interruptionHandler: AudioInterruptionHandler
        private let session: any AudioSessionProtocol
        private let notificationCenter: NotificationCenter
        private var tokens: [any NSObjectProtocol] = []
        private var isConfigured = false

        public init(
            engine: (any AudioEngineProtocol)?,
            session: any AudioSessionProtocol = AVAudioSession.sharedInstance(),
            notificationCenter: NotificationCenter = .default
        ) {
            self.interruptionHandler = AudioInterruptionHandler(engine: engine)
            self.session = session
            self.notificationCenter = notificationCenter
            observe()
        }

        isolated deinit {
            for token in tokens { notificationCenter.removeObserver(token) }
        }

        /// Sets the `.playback` category with the `.spokenAudio` mode. ``activate()`` calls it when
        /// needed, but the playback coordinator must call it before requesting to become the primary
        /// Now Playing app (ADR 0006).
        ///
        /// The route-sharing policy stays `.default`: `.longFormAudio` changes how routes are picked
        /// (AirPlay 2 routing, no picker in some cases) and needs device validation first.
        public func configure() throws {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            isConfigured = true
        }

        public func activate() throws {
            if !isConfigured { try configure() }
            try session.setActive(true, options: [])
        }

        public func deactivate() {
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                logger.error("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // MARK: - Notifications

        /// iOS 27 replaced `interruptionNotification` with a deactivation notification and a separate
        /// resumption recommendation. A system deactivation is an interruption; app-initiated ones
        /// (our own ``deactivate()``) are ignored.
        nonisolated static func deactivationEvent(_ userInfo: [AnyHashable: Any]?) -> AudioSessionEvent? {
            guard let context = userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
                context.source == .system
            else { return nil }
            return .interruptionBegan
        }

        nonisolated static func resumptionEvent(_ userInfo: [AnyHashable: Any]?) -> AudioSessionEvent? {
            guard let context = userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
            else { return nil }
            return .interruptionEnded(shouldResume: context.recommendation == .shouldResume)
        }

        nonisolated static func routeChangeEvent(_ userInfo: [AnyHashable: Any]?) -> AudioSessionEvent? {
            // Any lost output pauses, not only wired headphones as in the legacy app.
            guard let rawReason = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
            else { return nil }
            return .oldDeviceUnavailable
        }

        private func observe() {
            let handler = interruptionHandler
            tokens = [
                notificationCenter.addObserver(
                    forName: AVAudioSession.didBecomeInactiveNotification, object: session, queue: .main
                ) { notification in
                    guard let event = Self.deactivationEvent(notification.userInfo) else { return }
                    MainActor.assumeIsolated { handler.handle(event) }
                },
                notificationCenter.addObserver(
                    forName: AVAudioSession.resumptionRecommendationNotification, object: session, queue: .main
                ) { notification in
                    guard let event = Self.resumptionEvent(notification.userInfo) else { return }
                    MainActor.assumeIsolated { handler.handle(event) }
                },
                notificationCenter.addObserver(
                    forName: AVAudioSession.didBecomeActiveNotification, object: session, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { handler.handle(.sessionActivated) }
                },
                // After a media services reset the category is gone; reconfigure on next activation.
                notificationCenter.addObserver(
                    forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.isConfigured = false }
                },
                notificationCenter.addObserver(
                    forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
                ) { notification in
                    guard let event = Self.routeChangeEvent(notification.userInfo) else { return }
                    MainActor.assumeIsolated { handler.handle(event) }
                },
            ]
        }
    }
#endif
