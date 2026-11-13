import ABSCore
import ABSData
import Foundation
import Testing

@testable import ABSAppModel

@Suite
struct ItemDownloadStateTests {
    static let connection = DownloadsListingTests.connection
    static let book = "li-Walden"

    private static func state(
        episodeID: String? = nil, records: [DownloadRecordDTO] = [],
        progress: [UUID: DownloadsController.Progress] = [:], items: [LocalLibraryItemDTO] = []
    ) -> ItemDownloadState {
        ItemDownloadState(
            libraryItemID: book, episodeID: episodeID, connectionID: connection, records: records, progress: progress,
            localItems: items)
    }

    private static func record(_ state: DownloadState, parts: [(expected: Int64, written: Int64)] = [])
        -> DownloadRecordDTO
    {
        DownloadsListingTests.record("Walden", state: state, parts: parts)
    }

    @Test func nothingStoredIsNone() {
        let state = Self.state()
        #expect(state == .none)
        #expect(state.canStart)
        #expect(!state.canRetry)
        #expect(state.recordID == nil)
        #expect(state.localItemID == nil)
        #expect(state.fraction == nil)
    }

    @Test func aRecordMapsToItsState() {
        let queued = Self.record(.queued)
        #expect(Self.state(records: [queued]) == .queued(recordID: queued.id))

        let downloading = Self.record(.downloading, parts: [(expected: 400, written: 100)])
        #expect(Self.state(records: [downloading]) == .downloading(recordID: downloading.id, fraction: 0.25))
        // Live progress wins over the stored bytes.
        let live = [downloading.id: DownloadsController.Progress(fraction: 0.5, bytes: 200)]
        #expect(
            Self.state(records: [downloading], progress: live) == .downloading(recordID: downloading.id, fraction: 0.5))

        let paused = Self.record(.paused, parts: [(expected: 100, written: 100)])
        #expect(Self.state(records: [paused]) == .paused(recordID: paused.id, fraction: 1))

        let failed = Self.record(.failed)
        #expect(Self.state(records: [failed]) == .failed(recordID: failed.id))
    }

    @Test func actionsFollowTheState() {
        let id = UUID()
        let queued = ItemDownloadState.queued(recordID: id)
        #expect(!queued.canStart && !queued.canRetry && queued.recordID == id && queued.fraction == nil)
        let downloading = ItemDownloadState.downloading(recordID: id, fraction: 1.5)
        #expect(!downloading.canStart && !downloading.canRetry && downloading.recordID == id)
        #expect(downloading.fraction == 1)
        let paused = ItemDownloadState.paused(recordID: id, fraction: -1)
        #expect(paused.canRetry && paused.recordID == id && paused.fraction == 0)
        let failed = ItemDownloadState.failed(recordID: id)
        #expect(failed.canRetry && !failed.canStart && failed.recordID == id)
        let downloaded = ItemDownloadState.downloaded(localItemID: id)
        #expect(!downloaded.canStart && !downloaded.canRetry)
        #expect(downloaded.localItemID == id && downloaded.recordID == nil)
    }

    @Test func otherMediasRecordsDontCount() {
        let elsewhere = DownloadsListingTests.record(
            "Walden", state: .downloading, connection: DownloadsListingTests.otherConnection)
        let otherBook = DownloadsListingTests.record("Emma", state: .queued)
        let episode = DownloadsListingTests.record("Walden", state: .queued, episodeId: "ep-1")
        var coverOnly = Self.record(.queued)
        coverOnly.parts = [
            DownloadPartDTO(
                kind: .cover, serverPath: "/cover", filename: "cover.jpg", mimeType: "image/jpeg",
                destinationRelativePath: "cover.jpg")
        ]
        #expect(Self.state(records: [elsewhere, otherBook, episode, coverOnly]) == .none)
    }

    @Test func aLocalItemWithMediaFilesIsDownloaded() {
        let id = UUID()
        let audio = DownloadsListingTests.item("Walden", id: id, files: [DownloadsListingTests.file(size: 10)])
        #expect(Self.state(items: [audio]) == .downloaded(localItemID: id))
        let ebook = DownloadsListingTests.item(
            "Walden", id: id, files: [DownloadsListingTests.file(.ebook, size: 10, name: "w.epub")])
        #expect(Self.state(items: [ebook]) == .downloaded(localItemID: id))
    }

    @Test func localItemsWithoutMediaOrOfOtherMediaArentDownloaded() {
        let file = DownloadsListingTests.file(size: 10)
        let empty = DownloadsListingTests.item("Walden")
        let elsewhere = DownloadsListingTests.item(
            "Walden", connection: DownloadsListingTests.otherConnection, files: [file])
        let otherBook = DownloadsListingTests.item("Emma", files: [file])
        #expect(Self.state(items: [empty, elsewhere, otherBook]) == .none)
    }

    @Test func aRecordWinsOverTheLocalItem() {
        let record = Self.record(.queued)
        let item = DownloadsListingTests.item("Walden", files: [DownloadsListingTests.file(size: 10)])
        #expect(Self.state(records: [record], items: [item]) == .queued(recordID: record.id))
    }

    @Test func anEpisodeFollowsItsOwnRecordAndFiles() {
        let id = UUID()
        let podcast = DownloadsListingTests.item(
            "Walden", mediaType: .podcast, id: id,
            files: [DownloadsListingTests.file(size: 10, episodeId: "ep-1")])
        #expect(Self.state(episodeID: "ep-1", items: [podcast]) == .downloaded(localItemID: id))
        #expect(Self.state(episodeID: "ep-2", items: [podcast]) == .none)

        let record = DownloadsListingTests.record("Walden", state: .failed, episodeId: "ep-2")
        #expect(Self.state(episodeID: "ep-2", records: [record], items: [podcast]) == .failed(recordID: record.id))
        // The book's state ignores the episode's record.
        #expect(Self.state(records: [record]) == .none)
    }
}
