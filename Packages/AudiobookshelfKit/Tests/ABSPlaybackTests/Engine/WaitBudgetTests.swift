import Foundation
import Testing

/// The test waits survive a stall of the main actor longer than their timeout (#482): a busy CI
/// runner held the process for over ten seconds, and a wall-clock deadline then failed a wait whose
/// condition was about to hold. Stalls are simulated with a fake time source, so these tests never
/// block the main actor themselves (a real stall would flake other suites' timing windows).
@MainActor
struct WaitBudgetTests {
    /// A time source the test advances by hand.
    private final class FakeTime {
        private(set) var now = ContinuousClock.now

        func advance(by duration: Duration) { now += duration }
    }

    /// A condition that holds on its third check; its first check simulates a stall of the main
    /// actor that lasts longer than the wait's timeout.
    private final class StallingCondition {
        let time = FakeTime()
        private(set) var checks = 0

        func check() -> Bool {
            checks += 1
            if checks == 1 { time.advance(by: .seconds(1)) }
            return checks >= 3
        }
    }

    @Test func eventuallyOutlastsAStallLongerThanItsTimeout() async {
        let condition = StallingCondition()
        #expect(await eventually(timeout: .milliseconds(500), now: { condition.time.now }) { condition.check() })
        #expect(condition.checks == 3)
    }

    @Test func waitUntilOutlastsAStallLongerThanItsTimeout() async throws {
        let condition = StallingCondition()
        try await waitUntil(timeout: .milliseconds(500), now: { condition.time.now }) { condition.check() }
        #expect(condition.checks == 3)
    }

    /// Ordinary polling steps (here 10 ms) are charged in full, so a hang still ends on time.
    @Test func aConditionThatNeverHoldsStillTimesOut() async {
        let time = FakeTime()
        var checks = 0
        let held = await eventually(timeout: .milliseconds(200), now: { time.now }) {
            checks += 1
            time.advance(by: .milliseconds(10))
            return false
        }
        #expect(!held)
        #expect(checks == 20)
    }

    @Test func budgetChargesAtMostOneStepPerCheck() {
        let time = FakeTime()
        var budget = WaitBudget(.milliseconds(150), now: { time.now })
        time.advance(by: .seconds(30))
        let afterOneStall = budget.hasTimeLeft()
        time.advance(by: .seconds(30))
        let afterTwoStalls = budget.hasTimeLeft()
        #expect(afterOneStall)
        #expect(!afterTwoStalls)
    }

    @Test func budgetChargesGapsBelowTheCapInFull() {
        let time = FakeTime()
        var budget = WaitBudget(.milliseconds(150), now: { time.now })
        time.advance(by: .milliseconds(70))
        let afterFirst = budget.hasTimeLeft()
        time.advance(by: .milliseconds(70))
        let afterSecond = budget.hasTimeLeft()
        time.advance(by: .milliseconds(70))
        let afterThird = budget.hasTimeLeft()
        #expect(afterFirst && afterSecond)
        #expect(!afterThird)
    }
}
