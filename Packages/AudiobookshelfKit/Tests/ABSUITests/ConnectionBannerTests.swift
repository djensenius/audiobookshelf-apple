import Foundation
import Testing

@testable import ABSUI

@Suite struct ConnectionBannerTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let english = Locale(identifier: "en_US")

    @Test func statusesUseTheLegacyMessages() {
        #expect(ConnectionBannerStatus.offline.messageKey == "MessageNoNetworkConnection")
        #expect(ConnectionBannerStatus.checking.messageKey == "MessageAttemptingServerConnection")
        #expect(
            ConnectionBannerStatus.serverUnreachable(retryAt: now).messageKey
                == "MessageAudiobookshelfServerNotConnected")
        #expect(ConnectionBannerStatus.offline.message == "No network connection")
    }

    /// Retry only helps while the server is unreachable: offline it does nothing, and while checking
    /// a check is already running.
    @Test func onlyAnUnreachableServerOffersRetry() {
        #expect(ConnectionBannerStatus.serverUnreachable(retryAt: now).offersRetry)
        #expect(!ConnectionBannerStatus.offline.offersRetry)
        #expect(!ConnectionBannerStatus.checking.offersRetry)
    }

    /// The wait to the next check, rounded up to whole seconds and never negative.
    @Test func retryDescriptionCountsDownToTheNextCheck() throws {
        let status = ConnectionBannerStatus.serverUnreachable(retryAt: now.addingTimeInterval(4.2))
        let soon = try #require(status.retryDescription(at: now, locale: english))
        #expect(soon.hasPrefix("Retrying in") && soon.contains("5"))
        let minute = try #require(
            ConnectionBannerStatus.serverUnreachable(retryAt: now.addingTimeInterval(60))
                .retryDescription(at: now, locale: english))
        #expect(minute.contains("1") && !minute.contains("60"))
        let overdue = try #require(status.retryDescription(at: now.addingTimeInterval(30), locale: english))
        #expect(overdue.contains("0") && !overdue.contains("-"))
        #expect(ConnectionBannerStatus.offline.retryDescription(at: now) == nil)
        #expect(ConnectionBannerStatus.checking.retryDescription(at: now) == nil)
    }
}
