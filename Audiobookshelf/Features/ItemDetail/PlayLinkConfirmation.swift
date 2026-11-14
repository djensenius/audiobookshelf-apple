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
    /// The router's ``Router/navigationGeneration`` when the prompt was taken: newer navigation
    /// (another link, or a change to the Library path) supersedes it, so it no longer plays.
    var generation = 0
    /// Tells this prompt's alert from the ones before and after it on the screen;
    /// ``PlayLinkPromptState/receive(_:)`` assigns it.
    var id = 0

    /// The confirming button's `L10n` key.
    var confirmKey: String { isResume ? "ButtonItemDetailResume" : "ButtonPlay" }
    /// A paused item with a start time also offers to resume where it is.
    var offersCurrentPosition: Bool { isResume && link.startTime != nil }
}

/// The play-link alert's lifecycle on one screen (#577), kept apart from the view so its rules
/// can be tested; ``PlayLinkConfirmation`` only feeds it events.
///
/// A newer prompt while the alert is open never replaces it in place, since SwiftUI keeps an
/// open alert's data: the open alert closes first (``closingID``), then the newer prompt
/// presents (``didClose(_:)``). Only the newest one waits; a later one replaces it. Callbacks
/// from an older alert carry its ``PlayLinkPrompt/id`` and change nothing, and only the newest
/// prompt still standing may play, once.
struct PlayLinkPromptState {
    /// The prompt the alert presents, or is closing.
    private(set) var current: PlayLinkPrompt?
    /// The newest prompt waiting for ``current`` to close.
    private(set) var next: PlayLinkPrompt?
    /// ``current`` is closing: a newer prompt replaced it, or it was withdrawn.
    private(set) var isClosing = false
    /// The prompt Confirm may play: the newest received, until it is withdrawn or confirmed.
    private(set) var playableID: Int?
    private var lastID = 0

    /// What the alert presents: nothing while ``current`` closes.
    var presented: PlayLinkPrompt? { isClosing ? nil : current }
    /// The alert that must be gone before ``next`` presents.
    var closingID: Int? { isClosing ? current?.id : nil }

    /// A prompt taken from the router: presents now, or once the open alert has closed.
    mutating func receive(_ prompt: PlayLinkPrompt) {
        var prompt = prompt
        lastID += 1
        prompt.id = lastID
        playableID = prompt.id
        if current == nil {
            current = prompt
        } else {
            next = prompt
            isClosing = true
        }
    }

    /// Withdraws the prompts that no longer stand
    /// (``PlayLinkConfirmationPresentation/isCurrent(_:generation:screenIsPlayable:)``): newer
    /// navigation, or a screen that lost its media. A prompt taken after the navigation that
    /// moved `generation` carries the new one, so it stands.
    mutating func withdraw(generation: Int?, screenIsPlayable: Bool) {
        func stands(_ prompt: PlayLinkPrompt) -> Bool {
            PlayLinkConfirmationPresentation.isCurrent(
                prompt, generation: generation, screenIsPlayable: screenIsPlayable)
        }
        if let next, !stands(next) {
            self.next = nil
            if playableID == next.id { playableID = nil }
        }
        if let current, !stands(current) {
            isClosing = true
            if playableID == current.id { playableID = nil }
        }
    }

    /// The closing alert `id` is gone: the waiting prompt, if any, presents.
    mutating func didClose(_ id: Int) {
        guard closingID == id else { return }
        current = next
        next = nil
        isClosing = false
    }

    /// The alert for `id` closed: a button, or swiped away. An older alert's late callback
    /// changes nothing.
    mutating func dismissed(_ id: Int) {
        guard current?.id == id else { return }
        if isClosing {
            didClose(id)
        } else {
            current = nil
        }
    }

    /// Confirm on prompt `id`: whether it may play. Only the newest prompt still standing plays,
    /// and only once.
    mutating func confirm(_ id: Int) -> Bool {
        guard playableID == id else { return false }
        playableID = nil
        return true
    }
}

/// What an item or episode screen tells its play-link confirmation (#577): its title, and
/// whether it has anything to play.
struct PlayLinkScreen: Equatable {
    /// The book or episode's title once the screen has loaded; `nil` while it is loading. The
    /// server's title can be empty, so emptiness never decides anything: a load that ended
    /// without the media (not found, a failed load, or a podcast without the linked episode)
    /// reports `""` with ``isPlayable`` off, which is what dismisses the link.
    let title: String?
    /// Whether the loaded media has something to play, before ``gone`` is applied.
    let isPlayable: Bool
    /// The item's loads, for ``ItemDetailGoneState``: a reload that answered 404 keeps the
    /// retained book or episode on screen with Play disabled until a reload succeeds, and the
    /// link plays nothing then either. `nil` when the screen doesn't follow it.
    var gone: ItemDetailGoneState.Snapshot?

    /// Whether there is something to play, given the confirmation's remembered `goneState`
    /// (which records ``gone``): not while the item is gone from the server, as Play shows.
    func isPlayable(given goneState: ItemDetailGoneState) -> Bool {
        guard isPlayable else { return false }
        guard let gone else { return true }
        return !goneState.isGone(gone)
    }

    /// Whether a prompt already asked on this screen still stands: the media is still shown
    /// and playable. A refresh that answers 404, drops the episode or removes the audio
    /// withdraws it, as it disables Play.
    func keepsPrompt(given goneState: ItemDetailGoneState) -> Bool {
        title != nil && isPlayable(given: goneState)
    }

    /// The item screen: a book with audio that isn't missing. A podcast's own screen has nothing
    /// to play: its links name an episode, which opens on top.
    @MainActor
    static func item(_ model: ItemDetailModel) -> PlayLinkScreen {
        let gone = ItemDetailGoneState.Snapshot(model: model)
        if model.hasLoaded {
            return PlayLinkScreen(
                title: model.details?.title ?? "",
                isPlayable: model.mediaType != .podcast && model.playButton != .unavailable, gone: gone)
        }
        // As ``ItemDetailScreen`` shows a failed or not-found load.
        return PlayLinkScreen(title: model.error != nil && !model.isLoading ? "" : nil, isPlayable: false, gone: gone)
    }

    /// The episode screen, by the state it shows (``EpisodeDetailPresentation/screen(for:)``).
    @MainActor
    static func episode(_ model: EpisodeDetailModel) -> PlayLinkScreen {
        let gone = ItemDetailGoneState.Snapshot(model: model.detail)
        return switch EpisodeDetailPresentation.screen(for: model) {
        case .episode:
            PlayLinkScreen(
                title: model.episode?.title ?? "", isPlayable: model.playButton != .unavailable, gone: gone)
        case .notFound, .failed:
            PlayLinkScreen(title: "", isPlayable: false, gone: gone)
        case .loading:
            PlayLinkScreen(title: nil, isPlayable: false, gone: gone)
        }
    }
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
    /// The pending play link for the screen showing `route`: only while the screen is visible
    /// (between `onAppear` and `onDisappear`, as ``RefreshCommand``), the Library tab is selected,
    /// this screen is in its stack (`owner`), it is the screen the link opened and tops the path
    /// (``Router/pendingPlayLink(for:)``), and the full player doesn't cover it. The same route in
    /// another tab's stack never takes it, nor does a covered copy of it lower in the Library
    /// path, which the route alone can't tell from the one on top.
    @MainActor
    static func link(for route: Route, in router: Router?, owner: AppTab?, isVisible: Bool) -> PlayLink? {
        guard isVisible, let router, owner == .library, router.selectedTab == .library,
            !router.isFullPlayerPresented
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
    /// it is asked once; returns the question to show, if any, stamped with the router's
    /// ``Router/navigationGeneration``. Cancelling the question then plays nothing and leaves
    /// nothing pending.
    @MainActor
    static func take(_ resolution: PlayLinkResolution, from router: Router?) -> PlayLinkPrompt? {
        switch resolution {
        case .wait:
            return nil
        case .dismiss:
            router?.clearPendingPlayLink()
            return nil
        case .ask(var prompt):
            router?.clearPendingPlayLink()
            prompt.generation = router?.navigationGeneration ?? 0
            return prompt
        }
    }

    /// Whether `prompt` still stands: its screen still has the media to play
    /// (``PlayLinkScreen/keepsPrompt(given:)``, passed as `screenIsPlayable`), and no navigation
    /// came since it was taken. A newer link (even `item/` for the same screen, which the router
    /// doesn't push again) or a change to the Library path supersedes it, so its position never
    /// plays.
    @MainActor
    static func isCurrent(_ prompt: PlayLinkPrompt, in router: Router?, screenIsPlayable: Bool) -> Bool {
        isCurrent(prompt, generation: router?.navigationGeneration, screenIsPlayable: screenIsPlayable)
    }

    /// ``isCurrent(_:in:screenIsPlayable:)`` for the router's `generation`, `nil` without one.
    static func isCurrent(_ prompt: PlayLinkPrompt, generation: Int?, screenIsPlayable: Bool) -> Bool {
        guard screenIsPlayable, let generation else { return false }
        return generation == prompt.generation
    }

    /// Plays the confirmed link through `play`, the screens' own play path, so its streaming and
    /// cellular checks apply: from the link's start time, or with `atCurrentPosition` (a paused
    /// item) where it is. The same media, already loaded, resumes in its session from there
    /// rather than restarting. A prompt that no longer stands (``isCurrent(_:in:screenIsPlayable:)``:
    /// newer navigation, or a screen that lost its media) plays nothing. Returns what the alert
    /// shows when that fails, or `nil` once it starts, is cancelled or no longer stands.
    @MainActor
    static func confirm(
        _ prompt: PlayLinkPrompt, atCurrentPosition: Bool = false, in router: Router?, screenIsPlayable: Bool,
        with play: PlayItemAction
    ) async -> ItemDetailPlayFailure? {
        guard isCurrent(prompt, in: router, screenIsPlayable: screenIsPlayable) else { return nil }
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
        // An untitled book or episode (the server's title can be blank) is asked without its title.
        let isUntitled = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch (startTime.map { DurationStyle.timestamp.string($0, locale: locale) }, isUntitled) {
        case (let time?, false):
            message = L10n.string(
                isResume ? "MessagePlayLinkResumeFrom" : "MessagePlayLinkPlayFrom", title, time, locale: locale)
        case (let time?, true):
            message = L10n.string(
                isResume ? "MessagePlayLinkResumeFromUntitled" : "MessagePlayLinkPlayFromUntitled", time,
                locale: locale)
        case (nil, false):
            message = L10n.string(isResume ? "MessagePlayLinkResume" : "MessagePlayLinkPlay", title, locale: locale)
        case (nil, true):
            message = L10n.string(
                isResume ? "MessagePlayLinkResumeUntitled" : "MessagePlayLinkPlayUntitled", locale: locale)
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
    let screen: PlayLinkScreen
    @Environment(Router.self) private var router: Router?
    @Environment(\.navigationTab) private var owner
    @Environment(\.serverID) private var serverID
    @Environment(\.currentPlayback) private var playback
    @Environment(\.playItem) private var playItem
    @Environment(\.locale) private var locale
    /// Between `onAppear` and `onDisappear`: a covered screen in the stack never takes the link.
    @State private var isVisible = false
    /// Remembers a 404 through a failed retry, as the screen's Play does.
    @State private var goneState = ItemDetailGoneState()
    @State private var prompts = PlayLinkPromptState()
    @State private var playFailure: ItemDetailPlayFailure?

    func body(content: Content) -> some View {
        // The prompt this update presents; the alert's binding and buttons carry its id, so
        // callbacks from an alert already replaced change nothing.
        let presented = prompts.presented
        return
            content
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .onChange(of: screen.gone, initial: true) { _, snapshot in
                if let snapshot { goneState.update(snapshot) }
            }
            .onChange(of: resolution, initial: true) { _, resolution in
                if let next = PlayLinkConfirmationPresentation.take(resolution, from: router) { prompts.receive(next) }
            }
            // Newer navigation, or a refresh that takes the media away, withdraws the question;
            // Confirm checks again before playing. Either order with the handler above works:
            // a prompt taken after the navigation carries its generation.
            .onChange(of: PromptCheck(generation: router?.navigationGeneration, isPlayable: keepsPrompt)) {
                prompts.withdraw(generation: router?.navigationGeneration, screenIsPlayable: keepsPrompt)
            }
            // Once this update has closed the open alert, the waiting prompt presents.
            .onChange(of: prompts.closingID) { _, closingID in
                guard let closingID else { return }
                Task { @MainActor in prompts.didClose(closingID) }
            }
            .alert(
                Text(verbatim: presented?.message ?? ""),
                isPresented: Binding {
                    presented.map { prompts.presented?.id == $0.id } ?? false
                } set: {
                    if !$0, let presented { prompts.dismissed(presented.id) }
                },
                presenting: presented
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
        guard
            let link = PlayLinkConfirmationPresentation.link(
                for: route, in: router, owner: owner, isVisible: isVisible)
        else {
            return .wait
        }
        return PlayLinkConfirmationPresentation.resolve(
            link: link, title: screen.title, isPlayable: screen.isPlayable(given: goneState), canPlay: playItem != nil,
            routerServerID: router?.serverID, activeServerID: serverID, nowPlaying: playback?.mediaKey,
            isPlaying: playback?.isPlaybackRequested ?? false, locale: locale)
    }

    /// Whether the screen still has the media a shown prompt would play.
    private var keepsPrompt: Bool { screen.keepsPrompt(given: goneState) }

    /// What a shown prompt depends on, besides itself.
    private struct PromptCheck: Equatable {
        let generation: Int?
        let isPlayable: Bool
    }

    private func confirm(_ prompt: PlayLinkPrompt, atCurrentPosition: Bool) {
        guard let playItem, prompts.confirm(prompt.id) else { return }
        Task {
            playFailure = await PlayLinkConfirmationPresentation.confirm(
                prompt, atCurrentPosition: atCurrentPosition, in: router, screenIsPlayable: keepsPrompt,
                with: playItem)
        }
    }
}

extension View {
    /// Asks before playing the router's pending play link on this item or episode screen
    /// (``PlayLinkConfirmation``).
    func confirmsPlayLink(for route: Route, screen: PlayLinkScreen) -> some View {
        modifier(PlayLinkConfirmation(route: route, screen: screen))
    }
}
