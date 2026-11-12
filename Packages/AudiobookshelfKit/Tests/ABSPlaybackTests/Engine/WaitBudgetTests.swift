import Foundation
import Testing

/// The test waits survive a stall of the main actor longer than their timeout (#482): a busy CI
/// runner held the process for over ten seconds, and a wall-clock deadline then failed a wait whose
/// condition was about to hold.
/// Serialized: each test's stall would otherwise also stall the others' waits.
@MainActor
@Suite(.serialized)
struct WaitBudgetTests {
    /// A condition that holds on its third check, after its first check stalls the main actor for
    /// longer than the wait's timeout.
    private final class StallingCondition {
        private(set) var checks = 0

        func check() -> Bool {
            checks += 1
            if checks == 1 { Thread.sleep(forTimeInterval: 1) }
            return checks >= 3
        }
    }

    @Test func eventuallyOutlastsAStallLongerThanItsTimeout() async {
        let condition = StallingCondition()
        #expect(await eventually(timeout: .milliseconds(500)) { condition.check() })
        #expect(condition.checks == 3)
    }

    @Test func waitUntilOutlastsAStallLongerThanItsTimeout() async throws {
        let condition = StallingCondition()
        try await waitUntil(timeout: .milliseconds(500)) { condition.check() }
        #expect(condition.checks == 3)
    }

    @Test func aConditionThatNeverHoldsStillTimesOut() async {
        let start = ContinuousClock.now
        #expect(!(await eventually(timeout: .milliseconds(200)) { false }))
        #expect(ContinuousClock.now - start >= .milliseconds(200))
    }

    @Test func budgetChargesAtMostOneStepPerCheck() {
        var budget = WaitBudget(.milliseconds(150))
        Thread.sleep(forTimeInterval: 0.3)
        let afterOneStall = budget.hasTimeLeft()
        Thread.sleep(forTimeInterval: 0.3)
        let afterTwoStalls = budget.hasTimeLeft()
        #expect(afterOneStall)
        #expect(!afterTwoStalls)
    }
}
