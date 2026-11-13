import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import SwiftUI

/// The root of every window scene: shows what the session lifecycle's gate says (ADR 0004).
///
/// Links reach the scene here, from `onOpenURL` and Handoff. A link waits in ``links``,
/// tagged with ``SessionLifecycle/linkEpoch``, until a signed-in host can open it, so a cold launch
/// from a link, or a link that arrives while the session restores, isn't lost. Only a ready
/// session's shell gets the binding: during an account switch the outgoing shell has none, so the
/// incoming account's shell takes the link. Nothing arriving while signed out, signing out or
/// without a store is kept (``PendingLink/init(_:arrivingAt:epoch:)``), and the binding hands the
/// host a link only while the epoch is the one it arrived in, so a link queued for one account
/// never opens for another, even when this view didn't render the gates in between.
/// The lifecycle, accounts, shown `serverID` (``SceneContent/serverID``) and that connection's
/// playback history (``playbackHistorySource(_:serverID:)``) are in the environment of everything
/// below.
struct RootView: View {
    let lifecycle: SessionLifecycle
    let player: any PlayerSlotState
    let accounts: AccountManager?
    /// The shared library, injected into the signed-in shell (`\.libraryStore`).
    var library: LibraryParticipant?
    /// Given to the signed-in shell as `\.imagePipeline`; screens outside it see `nil`.
    var imagePipeline: ImagePipeline?
    /// The account session's playback, given to the signed-in shell as `\.playItem`,
    /// `\.bookmarkStore` and `\.sleepTimer` (``PlaybackEnvironment``).
    var playback: PlaybackSessionParticipant?
    /// The app's one history store, read by the shown shell's account only
    /// (``playbackHistorySource(_:serverID:)``).
    var playbackHistory: PlaybackHistoryStore?

    @Environment(\.scenePhase) private var scenePhase
    @State private var links = SceneLinks()
    /// Why a switch ended signed out, kept after dismissal so the text doesn't blank.
    @State private var switchSignedOutMessage: String?
    @State private var showsSwitchSignedOut = false
    /// A continued Handoff activity's account isn't signed in on this device.
    @State private var showsHandoffAccountMissing = false

    var body: some View {
        content
            .environment(lifecycle)
            .environment(accounts)
            .environment(\.serverID, SceneContent(lifecycle.gate).serverID)
            .environment(
                \.playbackHistorySource,
                Self.playbackHistorySource(playbackHistory, serverID: SceneContent(lifecycle.gate).serverID)
            )
            .task { await lifecycle.start() }
            // A count, not the gate: SwiftUI can coalesce the switch's gates. Every window shows it:
            // the switch replaced every window's shell, not only the one it was chosen in.
            .onChange(of: lifecycle.signedOutSwitches) {
                switchSignedOutMessage =
                    accounts?.signedOutSwitchMessage(after: lifecycle.signedOutSwitchError)
                    ?? L10n.string("MessageSwitchServerSignedOut")
                showsSwitchSignedOut = true
            }
            .alert(
                Text(verbatim: switchSignedOutMessage ?? ""), isPresented: $showsSwitchSignedOut,
                presenting: switchSignedOutMessage
            ) { _ in
                Button(role: .cancel) {
                } label: {
                    Text(verbatim: L10n.string("ButtonOk"))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                Task { await lifecycle.handle(scenePhase: SessionScenePhase(phase)) }
            }
            // Only a stale link goes: one that arrived after the bump carries the new epoch.
            .onChange(of: lifecycle.linkEpoch) { _, epoch in links.dropStale(atEpoch: epoch) }
            .onOpenURL { url in
                if let link = DeepLink(url: url) { receive(link) }
            }
            .onContinueUserActivity(DeepLink.handoffActivityType) { activity in
                if let handoff = HandoffActivity(userInfo: activity.userInfo) { receive(handoff) }
            }
            .alert(
                Text(verbatim: L10n.string("MessageHandoffAccountNotSignedIn")),
                isPresented: $showsHandoffAccountMissing
            ) {
                Button(role: .cancel) {
                } label: {
                    Text(verbatim: L10n.string("ButtonOk"))
                }
            }
            // A link or a continued activity goes to a window that exists instead of opening a new
            // one (macOS, and iPad windows).
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }

    /// The shared library store while it serves `identity`'s account, `nil` otherwise.
    private func servedStore(for identity: SessionIdentity) -> LibraryStore? {
        guard let store = library?.store, store.serves(identity) else { return nil }
        return store
    }

    /// `participant` while the active account is `identity`'s, `nil` otherwise. During a switch
    /// the outgoing shell stays up after `accounts` moved on, and must not play, bookmark or time
    /// with the next account's session.
    static func playback(
        _ participant: PlaybackSessionParticipant?, accounts: AccountManager?, for identity: SessionIdentity
    ) -> PlaybackSessionParticipant? {
        guard let accounts, let active = accounts.activeConnection,
            active.id == identity.connectionID, active.userId == identity.userID
        else { return nil }
        return participant
    }

    /// The active connection's client while it serves `identity`'s account, for `\.statsService`;
    /// `nil` otherwise. During a switch the outgoing shell stays up after `accounts` moved on, and
    /// must not load the next account's stats.
    static func statsService(_ accounts: AccountManager?, for identity: SessionIdentity) -> (any StatsService)? {
        guard let accounts, let active = accounts.activeConnection,
            active.id == identity.connectionID, active.userId == identity.userID
        else { return nil }
        return accounts.client
    }

    /// `store`'s history for the shell showing `serverID`'s connection, for
    /// `\.playbackHistorySource`; `nil` without a store or a shown shell.
    ///
    /// The store is the app's one and keeps every account's history (removing an account keeps
    /// it). Events are keyed by their connection, which is one user on one server, so the source
    /// reads only media on `serverID`'s connection: a key on another one, another account's
    /// media, gets no events. During a switch the outgoing shell keeps its own connection, so it
    /// still reads only its own account's history.
    static func playbackHistorySource(
        _ store: PlaybackHistoryStore?, serverID: UUID?
    ) -> PlaybackHistoryModel.EventSource? {
        guard let store, let serverID else { return nil }
        return { key in
            guard key.serverConnectionID == serverID else {
                return AsyncStream {
                    $0.yield([])
                    $0.finish()
                }
            }
            return try await store.updates(for: key)
        }
    }

    /// One link waits at a time: the last one received wins, including over a confirmed server
    /// switch's link (``SceneLinks``).
    private func receive(_ link: DeepLink) {
        links.receive(link, gate: lifecycle.gate, epoch: lifecycle.linkEpoch)
    }

    /// Resolves the activity's account to a connection here (ADR 0004, "Handoff"), then lets its
    /// link wait as if it had arrived when the activity did; or, when that account isn't signed
    /// in here, opens nothing and says so. It replaces the older links when it arrives; a result
    /// a newer link or a session change made stale does nothing (``SceneLinks``).
    private func receive(_ handoff: HandoffActivity) {
        let arrival = links.reserveArrival()
        let (gate, epoch) = (lifecycle.gate, lifecycle.linkEpoch)
        Task {
            let resolution = await lifecycle.resolve(handoff)
            let missing = links.receive(
                resolution, gate: gate, epoch: epoch, arrival: arrival, currentEpoch: lifecycle.linkEpoch)
            if missing != nil { showsHandoffAccountMissing = true }
        }
    }

    /// Checked when the host reads it, not only when the epoch changes: SwiftUI orders a new
    /// host's `onAppear` and this view's `onChange` arbitrarily.
    private var linkBinding: Binding<DeepLink?> {
        Binding(
            get: { links.link(atEpoch: lifecycle.linkEpoch) },
            set: { if $0 == nil { links.clearPending() } }
        )
    }

    @ViewBuilder private var content: some View {
        switch SceneContent(lifecycle.gate) {
        case .loading, .signingOut:
            LoadingView()
        case .connect:
            if let accounts {
                ConnectFlowView(accounts: accounts)
            } else {
                SignedOutPlaceholder()
            }
        case .shell(let identity, let opensLinks):
            // A switch keeps the old shell on screen until the next session has started, so a
            // sign-in presented from it isn't torn down. It is the same case as a ready session,
            // so the shell, its router and its scene storage survive until the identity changes.
            // A confirmed switch's link, opened after it with the new account's epoch.
            // The store, progress reader and item actions only while the store serves this
            // shell's account: during a switch the outgoing shell stays up after the store
            // attached the next account, and must not build services, read progress or act for
            // it with its own library and item IDs. Built once per shell, so once per session.
            AccountShell(store: servedStore(for: identity)) {
                SceneRouterHost(
                    identity: identity, player: player, pendingLink: opensLinks ? linkBinding : .constant(nil),
                    reopen: LinkReopener(
                        beginSwitch: { links.beginSwitch(with: $0, epoch: lifecycle.linkEpoch) },
                        finishSwitch: {
                            links.finishSwitch($0, gate: lifecycle.gate, epoch: lifecycle.linkEpoch)
                        }),
                    handoffArrivals: links.handoffArrivals
                )
                .environment(\.imagePipeline, imagePipeline)
            }
            .id(identity)
            .modifier(PlaybackEnvironment(participant: Self.playback(playback, accounts: accounts, for: identity)))
            // `AccountManager` is observable, so a sign-in, switch, reconnect or sign-out updates it.
            .environment(\.statsService, Self.statsService(accounts, for: identity))
        case .storeUnavailable:
            ErrorStateView(
                title: L10n.string("MessageStoreUnavailable"),
                message: L10n.string("MessageStoreUnavailableHelp"),
                systemImage: "externaldrive.badge.exclamationmark"
            )
        }
    }
}

extension SceneContent {
    /// The connection whose shell is on screen, for `\.serverID`: the ready account's, or the
    /// outgoing account's while a switch keeps its shell up; `nil` when no shell is shown.
    var serverID: UUID? {
        if case .shell(let identity, _) = self { identity.connectionID } else { nil }
    }
}

extension SessionScenePhase {
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .inactive: self = .inactive
        case .background: self = .background
        @unknown default: self = .inactive
        }
    }
}

#Preview("Signed out") {
    RootView(
        lifecycle: SessionLifecycle(source: SignedOutAccountSource()), player: PlaceholderPlayerState(), accounts: nil)
}

#Preview("Store unavailable") {
    RootView(
        lifecycle: SessionLifecycle(storeUnavailable: CocoaError(.fileWriteOutOfSpace)),
        player: PlaceholderPlayerState(), accounts: nil)
}
