import ABSAppModel
import ABSCore
import ABSData
import ABSPlayback
import SwiftUI
import Testing

@testable import Audiobookshelf

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

private struct FixedDevice: DeviceIdentifying {
    func deviceIdentifier() async -> String { "device" }
}

/// What the player's environment held.
@MainActor
private final class SleepTimerSighting {
    var sleepTimer: SleepTimer?
}

/// Stands in for the player and records `\.sleepTimer` as it reads it.
private struct SleepTimerProbe: View {
    let sighting: SleepTimerSighting
    @Environment(\.sleepTimer) private var sleepTimer

    var body: some View {
        let _ = sighting.sleepTimer = sleepTimer
        Color.clear
    }
}

/// Renders `view` once, so its body reads the environment.
@MainActor
private func render(_ view: some View) {
    #if canImport(AppKit)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
    #else
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.view.layoutIfNeeded()
    #endif
}

/// Each account session's scope, as the app configures it, has a sleep timer (#600) that the
/// player's environment gets and that ends with the session.
@MainActor
@Suite struct SleepTimerWiringTests {
    let accountA = SessionIdentity(connectionID: UUID(), userID: "a")
    let accountB = SessionIdentity(connectionID: UUID(), userID: "b")

    /// A participant over the app's real scopes; offline, so nothing is sent.
    private func withParticipant(_ body: (PlaybackSessionParticipant) async throws -> Void) async throws {
        let suiteName = "SleepTimerWiringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let writer = LocalProgressStore(modelContainer: try DataStack(location: .inMemory).container)
        let participant = PlaybackSessionParticipant(
            current: CurrentPlayback(), writer: writer, deviceIdentifiers: FixedDevice(), features: { _ in nil },
            requestSignOut: { _ in },
            makeScope: {
                AppPlayback.makeScope(
                    for: $0, settings: settings, policy: NetworkPolicy(monitor: NetworkMonitor(), settings: settings),
                    engine: AudioEngine(audioSession: nil), interruptions: nil, mediaLeases: nil)
            })
        try await body(participant)
        await participant.sessionWillEnd(.signOut)
    }

    private func start(_ participant: PlaybackSessionParticipant, _ identity: SessionIdentity, sessionID: UInt64)
        async
    {
        await participant.sessionDidStart(
            SessionContext(identity: identity, client: nil, isOffline: true, sessionID: sessionID))
    }

    /// The session's timer reaches the player's environment and can start.
    @Test func aSessionsTimerReachesThePlayer() async throws {
        try await withParticipant { participant in
            await start(participant, accountA, sessionID: 1)
            let timer = try #require(participant.sleepTimer)

            let sighting = SleepTimerSighting()
            render(SleepTimerProbe(sighting: sighting).modifier(PlaybackEnvironment(participant: participant)))

            #expect(sighting.sleepTimer === timer)
            #expect(timer.start(.duration(600)))
            #expect(timer.isRunning)
        }
    }

    /// Switching accounts cancels the outgoing account's running timer, and the next account gets
    /// a timer of its own that isn't running.
    @Test func switchingAccountsCancelsTheTimer() async throws {
        try await withParticipant { participant in
            await start(participant, accountA, sessionID: 1)
            let first = try #require(participant.sleepTimer)
            #expect(first.start(.duration(600)))

            await participant.sessionWillEnd(.switch)

            #expect(participant.sleepTimer == nil)
            #expect(!first.isRunning)

            await start(participant, accountB, sessionID: 2)
            let second = try #require(participant.sleepTimer)
            #expect(second !== first)
            #expect(!second.isRunning)
        }
    }

    /// Signing out cancels the running timer and leaves the player without one.
    @Test func signingOutCancelsTheTimer() async throws {
        try await withParticipant { participant in
            await start(participant, accountA, sessionID: 1)
            let timer = try #require(participant.sleepTimer)
            #expect(timer.start(.duration(600)))

            await participant.sessionWillEnd(.signOut)

            #expect(participant.sleepTimer == nil)
            #expect(!timer.isRunning)
            let sighting = SleepTimerSighting()
            sighting.sleepTimer = timer
            render(SleepTimerProbe(sighting: sighting).modifier(PlaybackEnvironment(participant: participant)))
            #expect(sighting.sleepTimer == nil)
        }
    }
}
