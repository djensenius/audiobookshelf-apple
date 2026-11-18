import Testing

@testable import ABSAppModel

/// The connection indicator's priority waits for a lasting problem (#691).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ConnectionProblemDebounceTests {
    let clock = ManualClock()

    @Test func aBriefProblemNeverPersists() async throws {
        let debounce = ConnectionProblemDebounce(clock: clock)
        var sleeps = clock.sleeps.makeAsyncIterator()

        debounce.update(.connecting)
        let timer = try #require(debounce.timer)
        #expect(await sleeps.next() == .seconds(3))
        clock.advance(by: .seconds(1))
        #expect(!debounce.hasPersisted)
        debounce.update(.connected(cellular: false, metered: false))
        await timer.value
        clock.advance(by: .seconds(5))
        #expect(!debounce.hasPersisted)
        #expect(debounce.timer == nil)
        #expect(clock.sleeperCount == 0)
    }

    @Test func aLastingProblemPersistsAfterTheDelay() async throws {
        let debounce = ConnectionProblemDebounce(clock: clock)
        var sleeps = clock.sleeps.makeAsyncIterator()

        debounce.update(.connecting)
        let timer = try #require(debounce.timer)
        #expect(await sleeps.next() == .seconds(3))
        clock.advance(by: .seconds(2))
        // Another problem doesn't restart the wait.
        debounce.update(.serverUnreachable)
        debounce.update(.offline)
        #expect(debounce.timer == timer)
        clock.advance(by: .milliseconds(999))
        #expect(!debounce.hasPersisted)

        clock.advance(by: .milliseconds(1))
        await timer.value
        #expect(debounce.hasPersisted)
        #expect(debounce.timer == nil)
        // Still a problem: nothing more to wait for.
        debounce.update(.offline)
        #expect(debounce.timer == nil)
        #expect(debounce.hasPersisted)
    }

    @Test(arguments: [ConnectionIndicatorState.connected(cellular: true, metered: true), nil])
    func aConnectionClearsItAtOnce(state: ConnectionIndicatorState?) async throws {
        let debounce = ConnectionProblemDebounce(clock: clock)
        var sleeps = clock.sleeps.makeAsyncIterator()
        debounce.update(.offline)
        let timer = try #require(debounce.timer)
        _ = await sleeps.next()
        clock.advance(by: .seconds(3))
        await timer.value
        #expect(debounce.hasPersisted)

        debounce.update(state)
        #expect(!debounce.hasPersisted)

        // A new problem waits again.
        debounce.update(.serverUnreachable)
        #expect(!debounce.hasPersisted)
        try #require(debounce.timer != nil)
        #expect(await sleeps.next() == .seconds(3))
    }

    @Test func onlyAWorkingConnectionIsntAProblem() {
        #expect(ConnectionIndicatorState.connecting.isProblem)
        #expect(ConnectionIndicatorState.offline.isProblem)
        #expect(ConnectionIndicatorState.serverUnreachable.isProblem)
        #expect(!ConnectionIndicatorState.connected(cellular: false, metered: false).isProblem)
        #expect(!ConnectionIndicatorState.connected(cellular: true, metered: true).isProblem)
    }
}
