import Testing

@testable import ABSCore

/// Each path is stamped with how many times its stream came back online (#337).
struct OnlineEpochCounterTests {
    @Test func countsEachReturnOnline() {
        let counter = OnlineEpochCounter()
        let epochs = [NetworkPath.wifi, .wifi, .offline, .offline, .cellular, .wired, .offline, .wifi].map {
            counter.stamp($0).onlineEpoch
        }
        #expect(epochs == [0, 0, 0, 0, 1, 1, 1, 2])
    }

    /// An offline first path counts its return like any other.
    @Test func anOfflineFirstPathCountsItsReturn() {
        let counter = OnlineEpochCounter()
        #expect([NetworkPath.offline, .wifi].map { counter.stamp($0).onlineEpoch } == [0, 1])
    }

    /// The epoch keeps a dropped offline path visible: the two online paths differ.
    @Test func pathsAcrossADroppedOfflinePathDiffer() {
        let counter = OnlineEpochCounter()
        let before = counter.stamp(.wifi)
        _ = counter.stamp(.offline)
        let after = counter.stamp(.wifi)
        #expect(before != after)
        #expect(after.onlineEpoch > before.onlineEpoch)
    }
}
