import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

@Suite struct ConnectionReachabilityTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func backoffDoublesFromFiveSecondsUpToAMinute() {
        let delays = (1...7).map { ConnectionReachability.delay(afterFailures: $0) }
        #expect(delays == [5, 10, 20, 40, 60, 60, 60].map { .seconds($0) })
    }

    @Test func failedPingsBackOffAndASuccessResets() {
        var reachability = ConnectionReachability()
        #expect(reachability.reduce(.retry) == .ping(attempt: 1, delay: .zero))
        #expect(reachability.state == .online)

        #expect(reachability.reduce(.pingFailed(attempt: 1, at: date)) == .ping(attempt: 2, delay: .seconds(5)))
        #expect(reachability.state == .serverUnreachable(retryAt: date.addingTimeInterval(5)))
        #expect(reachability.reduce(.pingStarted(attempt: 2)) == .none)
        #expect(reachability.state == .serverUnreachable(retryAt: nil))
        #expect(reachability.reduce(.pingFailed(attempt: 2, at: date)) == .ping(attempt: 3, delay: .seconds(10)))
        #expect(reachability.state == .serverUnreachable(retryAt: date.addingTimeInterval(10)))

        #expect(reachability.reduce(.pingSucceeded(attempt: 3)) == .none)
        #expect(reachability.state == .online && reachability.failures == 0)
        #expect(reachability.reduce(.retry) == .ping(attempt: 4, delay: .zero))
        #expect(reachability.reduce(.pingFailed(attempt: 4, at: date)) == .ping(attempt: 5, delay: .seconds(5)))
    }

    @Test func retryResetsTheBackoffAndShowsTheCheck() {
        var reachability = ConnectionReachability()
        _ = reachability.reduce(.retry)
        _ = reachability.reduce(.pingFailed(attempt: 1, at: date))
        _ = reachability.reduce(.pingFailed(attempt: 2, at: date))
        #expect(reachability.failures == 2)

        #expect(reachability.reduce(.retry) == .ping(attempt: 4, delay: .zero))
        #expect(reachability.state == .serverUnreachable(retryAt: nil) && reachability.failures == 0)
        #expect(reachability.reduce(.pingFailed(attempt: 4, at: date)) == .ping(attempt: 5, delay: .seconds(5)))
    }

    @Test func noNetworkStopsPingingUntilItComesBack() {
        var reachability = ConnectionReachability()
        _ = reachability.reduce(.retry)
        _ = reachability.reduce(.pingFailed(attempt: 1, at: date))

        #expect(reachability.reduce(.pathChanged(isOnline: false)) == .cancelPing)
        #expect(reachability.state == .offline(.noNetwork))
        #expect(reachability.reduce(.pathChanged(isOnline: false)) == .none)
        #expect(reachability.reduce(.retry) == .none)
        #expect(reachability.state == .offline(.noNetwork))

        #expect(reachability.reduce(.pathChanged(isOnline: true)) == .ping(attempt: 4, delay: .zero))
        #expect(reachability.state == .online && reachability.failures == 0)
        #expect(reachability.reduce(.pathChanged(isOnline: true)) == .none)
    }

    /// A ping that was superseded (by a retry, a network change or a newer ping) changes nothing.
    @Test func staleResultsAreIgnored() {
        var reachability = ConnectionReachability()
        _ = reachability.reduce(.retry)
        _ = reachability.reduce(.pathChanged(isOnline: false))

        #expect(reachability.reduce(.pingFailed(attempt: 1, at: date)) == .none)
        #expect(reachability.reduce(.pingSucceeded(attempt: 1)) == .none)
        #expect(reachability.state == .offline(.noNetwork))

        _ = reachability.reduce(.pathChanged(isOnline: true))
        _ = reachability.reduce(.pingFailed(attempt: 3, at: date))
        #expect(reachability.reduce(.pingSucceeded(attempt: 3)) == .none)
        #expect(reachability.reduce(.pingStarted(attempt: 3)) == .none)
        #expect(reachability.state == .serverUnreachable(retryAt: date.addingTimeInterval(5)))
    }

    /// The network coming back shows online before its ping; the ping succeeding bumps the
    /// verified revision once, so a load that failed in between is retried (#570).
    @Test func aPingConfirmingTheNetworkBumpsTheVerifiedRevisionOnce() {
        var reachability = ConnectionReachability()
        _ = reachability.reduce(.retry)
        _ = reachability.reduce(.pingSucceeded(attempt: 1))
        #expect(reachability.verifiedRevision == 1)

        _ = reachability.reduce(.pathChanged(isOnline: false))
        #expect(reachability.reduce(.pathChanged(isOnline: true)) == .ping(attempt: 3, delay: .zero))
        #expect(reachability.state == .online && reachability.verifiedRevision == 1)
        _ = reachability.reduce(.pingSucceeded(attempt: 3))
        #expect(reachability.state == .online && reachability.verifiedRevision == 2)

        // Further successes while confirmed, and stale ones, don't bump it.
        _ = reachability.reduce(.pingSucceeded(attempt: 3))
        #expect(reachability.reduce(.retry) == .ping(attempt: 4, delay: .zero))
        _ = reachability.reduce(.pingSucceeded(attempt: 4))
        _ = reachability.reduce(.pingSucceeded(attempt: 1))
        #expect(reachability.verifiedRevision == 2)

        // A failure, then a success, bumps it again.
        _ = reachability.reduce(.retry)
        _ = reachability.reduce(.pingFailed(attempt: 5, at: date))
        #expect(reachability.verifiedRevision == 2)
        _ = reachability.reduce(.pingSucceeded(attempt: 6))
        #expect(reachability.state == .online && reachability.verifiedRevision == 3)
    }

    @Test func statesExplainThemselves() {
        #expect(ConnectionBannerState.online.messageKey == nil)
        #expect(ConnectionBannerState.offline(.noNetwork).messageKey == "MessageNoNetworkConnection")
        #expect(
            ConnectionBannerState.serverUnreachable(retryAt: nil).messageKey
                == "MessageAudiobookshelfServerNotConnected")
    }
}

@Suite struct ServerActionAvailabilityTests {
    private let offline = ServerActionAvailability(connection: .offline(.noNetwork))
    private let unreachable = ServerActionAvailability(connection: .serverUnreachable(retryAt: nil))

    @Test func everythingIsAvailableOnline() {
        let online = ServerActionAvailability(connection: .online)
        #expect(online.reasonKey == nil)
        #expect(ItemActionKind.allCases.allSatisfy { online.reasonKey(for: $0, isDownloaded: false) == nil })
        #expect(ItemDetailMenuAction.allCases.allSatisfy { online.reasonKey(for: $0) == nil })
    }

    @Test func serverActionsExplainWhyTheyAreUnavailable() {
        let server: [ItemActionKind] = [.markFinished, .markNotFinished, .hideFromContinueListening, .addToPlaylist]
        for kind in server {
            #expect(offline.reasonKey(for: kind, isDownloaded: true) == "MessageNoNetworkConnection")
            #expect(unreachable.reasonKey(for: kind, isDownloaded: true) == "MessageAudiobookshelfServerNotConnected")
        }
        #expect(offline.reasonKey(for: .share, isDownloaded: false) == nil)
    }

    @Test func downloadedItemsStillPlayAndOpen() {
        for kind in [ItemActionKind.play, .openDetails, .openInNewWindow] {
            #expect(offline.reasonKey(for: kind, isDownloaded: true) == nil)
            #expect(offline.reasonKey(for: kind, isDownloaded: false) == "MessageNoNetworkConnection")
        }
    }

    @Test func detailMenuKeepsLocalEntries() {
        let disabled = ItemDetailMenuAction.allCases.filter { unreachable.reasonKey(for: $0) != nil }
        #expect(
            disabled == [.markFinished, .markNotFinished, .discardProgress, .hideFromContinueListening, .addToPlaylist])
        #expect(unreachable.reasonKey(for: .history) == nil)
    }
}
