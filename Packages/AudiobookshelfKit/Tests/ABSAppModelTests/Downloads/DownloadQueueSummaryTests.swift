import Foundation
import Testing

@testable import ABSAppModel

@Suite
struct DownloadQueueSummaryTests {
    typealias Fixtures = DownloadsListingTests

    @Test func hiddenWithoutDownloadsOrConnection() {
        let empty = DownloadQueueSummary(records: [], progress: [:], serverConnectionID: Fixtures.connection)
        #expect(!empty.isVisible)
        #expect(empty.count == 0)

        let signedOut = DownloadQueueSummary(
            records: [Fixtures.record("a", state: .queued)], progress: [:], serverConnectionID: nil)
        #expect(!signedOut.isVisible)
    }

    @Test func countsQueuedDownloadingAndPausedOfTheConnection() {
        let summary = DownloadQueueSummary(
            records: [
                Fixtures.record("queued", state: .queued),
                Fixtures.record("downloading", state: .downloading),
                Fixtures.record("paused", state: .paused),
                Fixtures.record("failed", state: .failed),
                Fixtures.record("other", state: .queued, connection: Fixtures.otherConnection),
            ],
            progress: [:], serverConnectionID: Fixtures.connection)

        #expect(summary.isVisible)
        #expect(summary.count == 3)
    }

    @Test func hiddenWhenOnlyFailedDownloadsRemain() {
        let summary = DownloadQueueSummary(
            records: [Fixtures.record("failed", state: .failed)], progress: [:],
            serverConnectionID: Fixtures.connection)
        #expect(!summary.isVisible)
    }

    @Test func fractionLeavesFailedDownloadsOutAndUsesLiveProgress() {
        let downloading = Fixtures.record("downloading", state: .downloading, parts: [(100, 10)])
        let summary = DownloadQueueSummary(
            records: [
                downloading,
                Fixtures.record("queued", state: .queued, parts: [(100, 0)]),
                Fixtures.record("failed", state: .failed, parts: [(1000, 0)]),
            ],
            progress: [downloading.id: .init(fraction: 0.5, bytes: 50)], serverConnectionID: Fixtures.connection)

        #expect(summary.count == 2)
        #expect(summary.fraction == 0.25)
    }
}
