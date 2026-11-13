import ABSAppModel
import ABSCore
import ABSData
import Foundation
import SwiftUI
import Testing

@testable import Audiobookshelf

#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// A history source that serves one snapshot and records the media it was asked for.
private actor FakeHistorySource {
    private let events: [PlaybackHistoryEventDTO]
    private(set) var requested: [MediaKey] = []

    init(events: [PlaybackHistoryEventDTO]) {
        self.events = events
    }

    func updates(for key: MediaKey) -> AsyncStream<[PlaybackHistoryEventDTO]> {
        requested.append(key)
        let events = events
        return AsyncStream { continuation in
            continuation.yield(events)
            continuation.finish()
        }
    }

    nonisolated var source: PlaybackHistoryModel.EventSource {
        { await self.updates(for: $0) }
    }
}

/// Records the plays the history screen asks for.
@MainActor
private final class PlayRecorder {
    struct Play: Equatable {
        let itemID: String
        let episodeID: String?
        let startTime: Double?
    }

    private(set) var plays: [Play] = []

    var action: PlayItemAction {
        PlayItemAction { [weak self] itemID, episodeID, startTime in
            self?.plays.append(Play(itemID: itemID, episodeID: episodeID, startTime: startTime))
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct PlaybackHistoryDestinationTests {
    private let connectionID = UUID()

    private func event(
        _ key: MediaKey, _ name: PlaybackHistoryEventName, at position: Double, minutesAgo: Double = 0
    ) -> PlaybackHistoryEventDTO {
        PlaybackHistoryEventDTO(
            serverConnectionID: key.serverConnectionID, mediaKey: key, mediaDisplayTitle: "The Episode", name: name,
            type: .playback, currentTime: position, timestamp: .now.addingTimeInterval(-minutesAgo * 60))
    }

    private func size(of view: some View) throws -> CGSize {
        let suiteName = "PlaybackHistoryDestinationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = NavigationStack { view }.environment(AppSettings(defaults: defaults))
        let proposal = CGSize(width: 400, height: 800)
        #if canImport(AppKit)
            return NSHostingController(rootView: root).sizeThatFits(in: proposal)
        #else
            return UIHostingController(rootView: root).sizeThatFits(in: proposal)
        #endif
    }

    @Test func showsTheEpisodesHistoryOnTheActiveConnection() async throws {
        let key = try #require(
            PlaybackHistoryDestination.mediaKey(serverID: connectionID, itemID: "li_1", episodeID: "ep_1"))
        #expect(key == MediaKey(serverConnectionID: connectionID, libraryItemId: "li_1", episodeId: "ep_1"))
        let fake = FakeHistorySource(events: [
            event(key, .pause, at: 3723), event(key, .play, at: 3000, minutesAgo: 10),
        ])

        let destination = PlaybackHistoryDestination(itemID: "li_1", episodeID: "ep_1")
            .environment(\.serverID, connectionID)
            .environment(\.playbackHistorySource, fake.source)
        let size = try size(of: destination)
        #expect(size.width > 0 && size.height > 0)

        let model = PlaybackHistoryDestination.model(mediaKey: key, source: fake.source, playItem: nil)
        await model.observe()
        #expect(await fake.requested.last == key)
        #expect(model.title == "The Episode")
        #expect(model.sections.flatMap { $0.rows }.map { $0.position } == [3723, 3000])
    }

    @Test func eventsPlayTheirMediaFromTheirPosition() async throws {
        let key = MediaKey(serverConnectionID: connectionID, libraryItemId: "li_1", episodeId: "ep_1")
        let fake = FakeHistorySource(events: [event(key, .seek, at: 120.5)])
        let recorder = PlayRecorder()
        let model = PlaybackHistoryDestination.model(mediaKey: key, source: fake.source, playItem: recorder.action)
        await model.observe()

        let row = try #require(model.sections.first?.rows.first)
        await model.play(from: row)
        #expect(recorder.plays == [.init(itemID: "li_1", episodeID: "ep_1", startTime: 120.5)])
    }

    @Test func showsNoHistoryWithoutASource() async {
        let key = MediaKey(serverConnectionID: connectionID, libraryItemId: "li_1")
        let model = PlaybackHistoryDestination.model(mediaKey: key, source: nil, playItem: nil)
        await model.observe()
        #expect(model.isLoaded && model.isEmpty && model.error == nil)
    }

    /// Negative control: without a connection there is no media to read, so the fake source is never asked.
    @Test func signedOutShowsNoConnection() async throws {
        #expect(PlaybackHistoryDestination.mediaKey(serverID: nil, itemID: "li_1", episodeID: nil) == nil)
        let fake = FakeHistorySource(events: [])
        let destination = PlaybackHistoryDestination(itemID: "li_1", episodeID: nil)
            .environment(\.playbackHistorySource, fake.source)
        let size = try size(of: destination)
        #expect(size.width > 0 && size.height > 0)
        #expect(await fake.requested.isEmpty)
    }
}
