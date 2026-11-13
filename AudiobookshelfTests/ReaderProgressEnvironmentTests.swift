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

/// What the reader's environment held.
@MainActor
private final class ReaderSighting {
    var makeEbookProgress: EbookProgressFactory?
}

/// Stands in for a reader and records `\.makeEbookProgress` as it reads it.
private struct ReaderProbe: View {
    let sighting: ReaderSighting
    @Environment(\.makeEbookProgress) private var makeEbookProgress

    var body: some View {
        let _ = sighting.makeEbookProgress = makeEbookProgress
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

/// `\.makeEbookProgress` in the signed-in shell and the macOS reader windows (#102, #104).
@MainActor
@Suite struct ReaderProgressEnvironmentTests {
    let accountA = SessionIdentity(connectionID: UUID(), userID: "a")
    let accountB = SessionIdentity(connectionID: UUID(), userID: "b")

    /// The account's real playback scope lends the factory; offline, so nothing is sent.
    private func withSession(
        _ body: (PlaybackSessionParticipant, LocalProgressStore) async throws -> Void
    ) async throws {
        let suiteName = "ReaderProgressEnvironmentTests.\(UUID().uuidString)"
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
                    engine: AudioEngine(audioSession: nil), interruptions: nil)
            })
        await participant.sessionDidStart(
            SessionContext(identity: accountA, client: nil, isOffline: true, sessionID: 1))
        try await body(participant, writer)
        await participant.sessionWillEnd(.signOut)
    }

    /// The environment builds models for the session's account, refuses another account's books,
    /// and a page turn in a model it built is saved under that account.
    @Test func readersGetModelsForTheSessionsAccountOnly() async throws {
        try await withSession { participant, writer in
            let sighting = ReaderSighting()
            render(ReaderProbe(sighting: sighting).modifier(ReaderProgressEnvironment(participant: participant)))
            let factory = try #require(sighting.makeEbookProgress)
            let bookA = MediaKey(serverConnectionID: accountA.connectionID, libraryItemId: "book")
            let bookB = MediaKey(serverConnectionID: accountB.connectionID, libraryItemId: "book")

            #expect(factory(bookB, .pdf, nil) == nil)
            let model = try #require(factory(bookA, .pdf, nil))
            model.record(.page(4), progress: 0.4)
            await model.flush()

            let row = try #require(try await writer.progress(for: bookA))
            #expect(row.ebookLocation == "4")
            #expect(row.ebookDirty)
            #expect(try await writer.progress(for: bookB) == nil)
        }
    }

    /// Without a session (signed out, or a switch's outgoing shell) readers save nothing.
    @Test func withoutASessionReadersGetNoFactory() async throws {
        try await withSession { participant, _ in
            let ended = try #require(participant.ebookProgress)
            await participant.sessionWillEnd(.switch)

            for source in [participant, nil] {
                let sighting = ReaderSighting()
                sighting.makeEbookProgress = ended
                render(ReaderProbe(sighting: sighting).modifier(ReaderProgressEnvironment(participant: source)))
                #expect(sighting.makeEbookProgress == nil)
            }
        }
    }
}
