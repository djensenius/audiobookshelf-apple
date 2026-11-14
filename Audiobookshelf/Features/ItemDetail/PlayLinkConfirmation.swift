import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import SwiftUI

/// The question a play link (a `play/` URL with `t=`, or a continued player Handoff activity)
/// asks on its item or episode screen before anything plays (ADR 0004, "Play links never start
/// playback silently"; #577).
struct PlayLinkPrompt: Equatable {
    let link: PlayLink
    /// The item is loaded but paused (``PlayLinkDecision/confirmResume(startTime:)``): Resume rather
    /// than Play.
    let isResume: Bool
    /// "Play "Dune" from 1:23:45?", or without the time when the link has none.
    let message: String

    /// The confirming button's `L10n` key.
    var confirmKey: String { isResume ? "ButtonItemDetailResume" : "ButtonPlay" }
    /// A paused item with a start time also offers to resume where it is.
    var offersCurrentPosition: Bool { isResume && link.startTime != nil }
}

/// What a screen does with the router's pending play link, from
/// ``PlayLinkConfirmationPresentation/resolve(link:title:isPlayable:canPlay:routerServerID:activeServerID:nowPlaying:isPlaying:locale:)``.
enum PlayLinkResolution: Equatable {
    /// Nothing to ask yet: no link for this screen, the screen hasn't loaded, there is no player,
    /// or the scene's account isn't the active one. The link stays pending.
    case wait
    /// Open only: the media is already playing, or there is nothing to play. Drops the link.
    case dismiss
    /// Ask before playing. Drops the link; the prompt carries it from here.
    case ask(PlayLinkPrompt)
}

/// The play-link confirmation's rules, kept apart from the view so they can be tested (#577).
enum PlayLinkConfirmationPresentation {
    /// The pending play link for the screen showing `route`: only while the Library tab is
    /// selected, this screen is in its stack (`owner`), it is the screen the link opened and tops
    /// the path (``Router/pendingPlayLink(for:)``), and the full player doesn't cover it. The same
    /// route in another tab's stack never takes it.
    @MainActor
    static func link(for route: Route, in router: Router?, owner: AppTab?) -> PlayLink? {
        guard let router, owner == .library, router.selectedTab == .library, !router.isFullPlayerPresented
        else { return nil }
        return router.pendingPlayLink(for: route)
    }

    /// Decides what to do with `link` on its loaded screen, following ``PlayLinkDecision``.
    ///
    /// - Parameters:
    ///   - title: The book or episode's title; `nil` until the screen has loaded it.
    ///   - isPlayable: The screen has something to play (audio, not missing). A podcast's own
    ///     screen doesn't, since a link without an episode has nothing to play.
    ///   - canPlay: The environment has a `playItem` action, `nil` while signed out.
    ///   - routerServerID: The scene router's server, which ``Router/open(_:)`` checked the link
    ///     against. It must be the active connection, whose `playItem` plays it; otherwise the
    ///     link waits for the router's identity change, which drops it.
    ///   - nowPlaying: The player's media. Media from another connection doesn't count as loaded.
    ///   - isPlaying: Whether playback is requested (playing or buffering), not paused.
    static func resolve(
        link: PlayLink?, title: String?, isPlayable: Bool, canPlay: Bool, routerServerID: String?,
        activeServerID: UUID?, nowPlaying: MediaKey?, isPlaying: Bool, locale: Locale
    ) -> PlayLinkResolution {
        guard let link, let title, canPlay, let activeServerID,
            routerServerID.flatMap(UUID.init(uuidString:)) == activeServerID
        else { return .wait }
        guard isPlayable else { return .dismiss }
        let loaded = nowPlaying?.serverConnectionID == activeServerID ? nowPlaying : nil
        switch PlayLinkDecision.decide(link, nowPlaying: loaded, isPlaying: isPlaying) {
        case .openOnly:
            return .dismiss
        case .confirmPlay(let startTime):
            return .ask(prompt(link, isResume: false, title: title, startTime: startTime, locale: locale))
        case .confirmResume(let startTime):
            return .ask(prompt(link, isResume: true, title: title, startTime: startTime, locale: locale))
        }
    }

    /// Acts on `resolution`: an open-only link or a question drops the router's pending link, so
    /// it is asked once; returns the question to show, if any. Cancelling the question then
    /// plays nothing and leaves nothing pending.
    @MainActor
    static func take(_ resolution: PlayLinkResolution, from router: Router?) -> PlayLinkPrompt? {
        switch resolution {
        case .wait:
            return nil
        case .dismiss:
            router?.clearPendingPlayLink()
            return nil
        case .ask(let prompt):
            router?.clearPendingPlayLink()
            return prompt
        }
    }

    /// Plays the confirmed link through `play`, the screens' own play path, so its streaming and
    /// cellular checks apply: from the link's start time, or with `atCurrentPosition` (a paused
    /// item) where it is. The same media, already loaded, resumes in its session from there
    /// rather than restarting. Returns what the alert shows when that fails, or `nil` once it
    /// starts or is cancelled.
    @MainActor
    static func confirm(_ prompt: PlayLinkPrompt, atCurrentPosition: Bool = false, with play: PlayItemAction) async
        -> ItemDetailPlayFailure?
    {
        let link = prompt.link
        do {
            try await play(
                itemID: link.itemID, episodeID: link.episodeID, startTime: atCurrentPosition ? nil : link.startTime)
            return nil
        } catch {
            guard let failure = ItemDetailPlayFailure(error: error) else { return nil }
            Log.playback.error(
                "Couldn't play link \(link.itemID, privacy: .private(mask: .hash)): \(failure.message, privacy: .private)"
            )
            return failure
        }
    }

    private static func prompt(
        _ link: PlayLink, isResume: Bool, title: String, startTime: TimeInterval?, locale: Locale
    ) -> PlayLinkPrompt {
        let message: String
        if let startTime {
            message = L10n.string(
                isResume ? "MessagePlayLinkResumeFrom" : "MessagePlayLinkPlayFrom", title,
                DurationStyle.timestamp.string(startTime, locale: locale), locale: locale)
        } else {
            message = L10n.string(isResume ? "MessagePlayLinkResume" : "MessagePlayLinkPlay", title, locale: locale)
        }
        return PlayLinkPrompt(link: link, isResume: isResume, message: message)
    }
}

/// Shows the router's pending play link on the item or episode screen it opened, as a centred
/// alert like the chapter confirmation: Play (or Resume, and Resume at Current Position), and
/// Cancel (#577). Leaving the screen before it asks drops the link in the router; once asked,
/// the alert holds it.
struct PlayLinkConfirmation: ViewModifier {
    let route: Route
    /// The title, once loaded.
    let title: String?
    let isPlayable: Bool
    @Environment(Router.self) private var router: Router?
    @Environment(\.navigationTab) private var owner
    @Environment(\.serverID) private var serverID
    @Environment(\.currentPlayback) private var playback
    @Environment(\.playItem) private var playItem
    @Environment(\.locale) private var locale
    @State private var prompt: PlayLinkPrompt?
    @State private var playFailure: ItemDetailPlayFailure?

    func body(content: Content) -> some View {
        content
            .onChange(of: resolution, initial: true) { _, resolution in
                if let next = PlayLinkConfirmationPresentation.take(resolution, from: router) { prompt = next }
            }
            .alert(
                Text(verbatim: prompt?.message ?? ""),
                isPresented: Binding {
                    prompt != nil
                } set: {
                    if !$0 { prompt = nil }
                },
                presenting: prompt
            ) { prompt in
                Button {
                    confirm(prompt, atCurrentPosition: false)
                } label: {
                    Text(verbatim: L10n.string(prompt.confirmKey))
                }
                if prompt.offersCurrentPosition {
                    Button {
                        confirm(prompt, atCurrentPosition: true)
                    } label: {
                        Text(verbatim: L10n.string("ButtonPlayLinkResumeCurrentPosition"))
                    }
                }
                Button(role: .cancel) {
                } label: {
                    Text(verbatim: L10n.string("ButtonCancel"))
                }
            }
            .alert(
                Text(verbatim: L10n.string("MessagePlaybackStartFailed")),
                isPresented: Binding {
                    playFailure != nil
                } set: {
                    if !$0 { playFailure = nil }
                },
                presenting: playFailure
            ) { _ in
            } message: { failure in
                Text(verbatim: failure.message)
            }
    }

    /// Reads the player only while a link waits for this screen, so playback doesn't re-render it.
    private var resolution: PlayLinkResolution {
        guard let link = PlayLinkConfirmationPresentation.link(for: route, in: router, owner: owner) else {
            return .wait
        }
        return PlayLinkConfirmationPresentation.resolve(
            link: link, title: title, isPlayable: isPlayable, canPlay: playItem != nil,
            routerServerID: router?.serverID, activeServerID: serverID, nowPlaying: playback?.mediaKey,
            isPlaying: playback?.isPlaybackRequested ?? false, locale: locale)
    }

    private func confirm(_ prompt: PlayLinkPrompt, atCurrentPosition: Bool) {
        guard let playItem else { return }
        Task {
            playFailure = await PlayLinkConfirmationPresentation.confirm(
                prompt, atCurrentPosition: atCurrentPosition, with: playItem)
        }
    }
}

extension View {
    /// Asks before playing the router's pending play link on this item or episode screen
    /// (``PlayLinkConfirmation``).
    func confirmsPlayLink(for route: Route, title: String?, isPlayable: Bool) -> some View {
        modifier(PlayLinkConfirmation(route: route, title: title, isPlayable: isPlayable))
    }
}
