import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

/// Counts restores and the epoch the restorer reads.
@MainActor
private final class Account {
    /// `nil` while a restore isn't wanted, such as signed in.
    var epoch: Int? = 1
    private(set) var restores = 0
    /// Holds each restore until opened, when set.
    var hold: Gate?

    func restorer(clock: ManualClock, state: ConnectionBannerState = .online) -> ReconnectRestorer {
        ReconnectRestorer(
            state: state, clock: clock, epoch: { [weak self] in self?.epoch.map(AnyHashable.init) },
            restore: { [weak self] in
                self?.restores += 1
                await self?.hold?.wait()
            })
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ReconnectRestorerTests {
    private let unreachable = ConnectionBannerState.serverUnreachable(retryAt: nil)
    private let offline = ConnectionBannerState.offline(.noNetwork)

    /// Comes online, then waits out the debounce and lets the waiting restore finish.
    private func comeOnline(
        _ restorer: ReconnectRestorer, clock: ManualClock, sleeps: inout AsyncStream<Duration>.Iterator
    ) async {
        restorer.observe(.online)
        guard let waiting = restorer.waiting else { return }
        #expect(await sleeps.next(isolation: #isolation) == ReconnectRestorer.debounce)
        clock.advance(by: ReconnectRestorer.debounce)
        await waiting.value
    }

    @Test(arguments: [ConnectionBannerState.offline(.noNetwork), .serverUnreachable(retryAt: nil)])
    func restoresOncePerTransitionToOnline(from previous: ConnectionBannerState) async {
        let clock = ManualClock()
        var sleeps = clock.sleeps.makeAsyncIterator()
        let account = Account()
        let restorer = account.restorer(clock: clock, state: previous)

        restorer.observe(.online)
        #expect(await sleeps.next(isolation: #isolation) == ReconnectRestorer.debounce)
        // Control: nothing before the debounce.
        #expect(account.restores == 0)
        let waiting = restorer.waiting
        clock.advance(by: ReconnectRestorer.debounce)
        await waiting?.value
        #expect(account.restores == 1)

        // Staying online restores nothing more.
        restorer.observe(.online)
        #expect(restorer.waiting == nil)
        #expect(account.restores == 1)

        // The next transition restores again.
        restorer.observe(previous)
        await comeOnline(restorer, clock: clock, sleeps: &sleeps)
        #expect(account.restores == 2)
    }

    @Test func nothingWhileTheAccountIsSignedIn() async {
        let clock = ManualClock()
        var sleeps = clock.sleeps.makeAsyncIterator()
        let account = Account()
        account.epoch = nil
        let restorer = account.restorer(clock: clock, state: offline)

        restorer.observe(.online)
        #expect(restorer.waiting == nil)
        #expect(clock.sleeperCount == 0)

        // Control: the same transition while offline restores.
        account.epoch = 1
        restorer.observe(offline)
        await comeOnline(restorer, clock: clock, sleeps: &sleeps)
        #expect(account.restores == 1)
    }

    @Test func nothingWhileTheBannerStaysOnlineOrOffline() {
        let account = Account()
        let restorer = account.restorer(clock: ManualClock())
        restorer.observe(.online)
        restorer.observe(offline)
        restorer.observe(unreachable)
        #expect(restorer.waiting == nil)
        #expect(account.restores == 0)
    }

    /// A sign-out or switch during the debounce, or another session of the same account.
    @Test func nothingOnceTheEpochChanges() async {
        let clock = ManualClock()
        var sleeps = clock.sleeps.makeAsyncIterator()
        let account = Account()
        let restorer = account.restorer(clock: clock, state: offline)

        restorer.observe(.online)
        #expect(await sleeps.next(isolation: #isolation) == ReconnectRestorer.debounce)
        account.epoch = 2
        let waiting = restorer.waiting
        clock.advance(by: ReconnectRestorer.debounce)
        await waiting?.value
        #expect(account.restores == 0)

        // Signed out meanwhile.
        restorer.observe(offline)
        restorer.observe(.online)
        #expect(await sleeps.next(isolation: #isolation) == ReconnectRestorer.debounce)
        account.epoch = nil
        let signedOut = restorer.waiting
        clock.advance(by: ReconnectRestorer.debounce)
        await signedOut?.value
        #expect(account.restores == 0)

        // Control: an unchanged epoch restores.
        account.epoch = 3
        restorer.observe(offline)
        await comeOnline(restorer, clock: clock, sleeps: &sleeps)
        #expect(account.restores == 1)
    }

    @Test func flapsCoalesceIntoOneRestore() async {
        let clock = ManualClock()
        var sleeps = clock.sleeps.makeAsyncIterator()
        let account = Account()
        let restorer = account.restorer(clock: clock, state: offline)

        for _ in 0..<3 {
            restorer.observe(.online)
            #expect(await sleeps.next(isolation: #isolation) == ReconnectRestorer.debounce)
            clock.advance(by: .seconds(1))
            restorer.observe(offline)
        }
        // A failed ping after coming online cancels it too.
        restorer.observe(.online)
        #expect(await sleeps.next(isolation: #isolation) == ReconnectRestorer.debounce)
        restorer.observe(unreachable)
        #expect(restorer.waiting == nil)
        while clock.sleeperCount > 0, !Task.isCancelled { await Task.yield() }
        #expect(account.restores == 0)

        await comeOnline(restorer, clock: clock, sleeps: &sleeps)
        #expect(account.restores == 1)
    }

    /// A restore that is running isn't cancelled, and no other starts until it ends.
    @Test func aRunningRestoreIsNeitherCancelledNorOverlapped() async {
        let clock = ManualClock()
        var sleeps = clock.sleeps.makeAsyncIterator()
        let account = Account()
        let hold = Gate()
        account.hold = hold
        let restorer = account.restorer(clock: clock, state: offline)

        restorer.observe(.online)
        #expect(await sleeps.next(isolation: #isolation) == ReconnectRestorer.debounce)
        let running = restorer.waiting
        clock.advance(by: ReconnectRestorer.debounce)
        #expect(await eventually { account.restores == 1 })

        restorer.observe(offline)
        restorer.observe(.online)
        #expect(restorer.waiting == nil)
        hold.open()
        await running?.value
        #expect(account.restores == 1)

        // Control: once it ended, the next transition restores.
        account.hold = nil
        restorer.observe(offline)
        await comeOnline(restorer, clock: clock, sleeps: &sleeps)
        #expect(account.restores == 2)
    }

    /// The banner model reports each change of its state, as the restorer needs.
    @Test func theBannerReportsItsStateChanges() async {
        let (paths, feed) = AsyncStream.makeStream(of: NetworkPath.self)
        let model = ConnectionBannerModel(paths: { paths }, ping: {}, clock: ManualClock())
        var seen: [ConnectionBannerState] = []
        model.stateDidChange = { seen.append($0) }
        let run = Task { await model.run() }
        feed.yield(.offline)
        #expect(await eventually { seen == [.offline(.noNetwork)] })
        feed.yield(.wifi)
        #expect(await eventually { seen == [.offline(.noNetwork), .online] })
        run.cancel()
        await run.value
    }
}
