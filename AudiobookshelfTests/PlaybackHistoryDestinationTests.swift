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

/// A history source that serves one snapshot, recording the media it was asked for and when a reader takes the snapshot.
private actor FakeHistorySource {
    private let events: [PlaybackHistoryEventDTO]
    private(set) var requested: [MediaKey] = []
    private(set) var deliveries = 0
    private var requestWaiters: [CheckedContinuation<MediaKey, Never>] = []
    private var deliveryWaiters: [CheckedContinuation<Void, Never>] = []

    init(events: [PlaybackHistoryEventDTO]) {
        self.events = events
    }

    func updates(for key: MediaKey) -> AsyncStream<[PlaybackHistoryEventDTO]> {
        requested.append(key)
        for waiter in requestWaiters { waiter.resume(returning: key) }
        requestWaiters = []
        let stream = requested.count
        // Pull-based, so a delivery means the reader iterated, not just that the stream exists.
        return AsyncStream { await self.next(on: stream) }
    }

    private var served: Set<Int> = []

    private func next(on stream: Int) -> [PlaybackHistoryEventDTO]? {
        guard served.insert(stream).inserted else { return nil }
        deliveries += 1
        for waiter in deliveryWaiters { waiter.resume() }
        deliveryWaiters = []
        return events
    }

    /// The first media asked for, once something asks.
    func firstRequest() async -> MediaKey {
        if let first = requested.first { return first }
        return await withCheckedContinuation { requestWaiters.append($0) }
    }

    /// Returns once a reader has taken the snapshot.
    func firstDelivery() async {
        if deliveries > 0 { return }
        await withCheckedContinuation { deliveryWaiters.append($0) }
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

    /// `content` in a window, not shown, so its tasks run as they would on screen. Close it when done.
    private func mount(_ content: some View) -> Mounted {
        #if os(macOS)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 400, height: 800), styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: NavigationStack { content })
            window.contentView?.layoutSubtreeIfNeeded()
            return Mounted(window: window)
        #else
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
            window.rootViewController = UIHostingController(rootView: NavigationStack { content })
            window.isHidden = false
            window.layoutIfNeeded()
            return Mounted(window: window)
        #endif
    }

    @Test func mountedDestinationReadsTheEpisodesHistoryFromItsSource() async throws {
        let key = MediaKey(serverConnectionID: connectionID, libraryItemId: "li_1", episodeId: "ep_1")
        let fake = FakeHistorySource(events: [event(key, .pause, at: 3723)])
        let mounted = mount(
            PlaybackHistoryDestination(itemID: "li_1", episodeID: "ep_1")
                .environment(\.serverID, connectionID)
                .environment(\.playbackHistorySource, fake.source))
        defer { mounted.close() }

        #expect(await fake.firstRequest() == key)
        await fake.firstDelivery()
        #expect(await fake.requested == [key])
    }

    /// Control: a book's history is read under its item alone, with no episode.
    @Test func mountedBookDestinationReadsTheItemsHistory() async throws {
        let key = MediaKey(serverConnectionID: connectionID, libraryItemId: "li_2")
        let fake = FakeHistorySource(events: [event(key, .pause, at: 60)])
        let mounted = mount(
            PlaybackHistoryDestination(itemID: "li_2", episodeID: nil)
                .environment(\.serverID, connectionID)
                .environment(\.playbackHistorySource, fake.source)
                .environment(\.playItem, PlayRecorder().action))
        defer { mounted.close() }

        #expect(await fake.firstRequest() == key)
        await fake.firstDelivery()
        #expect(await fake.requested == [key])
    }

    @Test func modelGroupsTheSourcesEventsNewestFirst() async throws {
        let key = try #require(
            PlaybackHistoryDestination.mediaKey(serverID: connectionID, itemID: "li_1", episodeID: "ep_1"))
        #expect(key == MediaKey(serverConnectionID: connectionID, libraryItemId: "li_1", episodeId: "ep_1"))
        let fake = FakeHistorySource(events: [
            event(key, .pause, at: 3723), event(key, .play, at: 3000, minutesAgo: 10),
        ])

        let model = PlaybackHistoryDestination.model(mediaKey: key, source: fake.source, playItem: nil)
        await model.observe()
        #expect(model.title == "The Episode")
        #expect(model.sections.flatMap { $0.rows }.map { $0.position } == [3723, 3000])
    }

    @Test func rowsCanOnlyBePlayedWithAPlayer() async throws {
        let key = MediaKey(serverConnectionID: connectionID, libraryItemId: "li_1")
        let fake = FakeHistorySource(events: [event(key, .seek, at: 60)])
        let withoutPlayer = PlaybackHistoryDestination.model(mediaKey: key, source: fake.source, playItem: nil)
        await withoutPlayer.observe()
        let row = try #require(withoutPlayer.sections.first?.rows.first)
        #expect(!withoutPlayer.canPlay(row))

        let recorder = PlayRecorder()
        let withPlayer = PlaybackHistoryDestination.model(mediaKey: key, source: fake.source, playItem: recorder.action)
        #expect(withPlayer.canPlay(row))
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

/// A mounted view's window.
@MainActor
private struct Mounted {
    #if os(macOS)
        let window: NSWindow
    #else
        let window: UIWindow
    #endif

    func close() {
        #if os(macOS)
            window.close()
        #else
            window.isHidden = true
        #endif
    }
}
