import ABSAPI
import ABSCore
import Foundation
import Testing

@testable import ABSAppModel

@MainActor
@Suite struct NewPodcastDraftTests {
    let service = FakeAddPodcastService()

    func makeDraft(
        directory: PodcastDirectoryResult? = directoryResult("Directory Title"), feed: PodcastFeed = podcastFeed(),
        folders: [LibraryFolder] = podcastFolders
    ) -> NewPodcastDraft {
        NewPodcastDraft(
            service: service, libraryID: "lib", folders: folders, feed: feed, directory: directory,
            feedURL: "https://looked.up/feed")
    }

    @Test func theDirectoryEntryWinsOverTheFeed() {
        let draft = makeDraft()
        #expect(draft.title == "Directory Title" && draft.author == "Artist")
        #expect(draft.description == "<p>Directory</p>" && draft.genres == ["Fiction"])
        #expect(draft.feedURL == "https://feeds.example.com/show.xml")
        #expect(draft.imageURL == "https://images.example.com/c.jpg")
        #expect(draft.folderID == "f1" && !draft.autoDownloadEpisodes)
        let metadata = draft.request?.media.metadata
        #expect(metadata?.itunesID == "1" && metadata?.itunesArtistID == "2")
        #expect(metadata?.itunesPageURL == "https://podcasts.example.com/id1" && metadata?.releaseDate == "2026-01-01")
        #expect(metadata?.explicit == true && metadata?.language == "en" && metadata?.type == "serial")
    }

    @Test func aPastedFeedFillsTheFormFromTheFeed() {
        let draft = makeDraft(directory: nil)
        #expect(draft.title == "Feed Title" && draft.author == "Feed Author")
        #expect(draft.description == "Feed" && draft.genres == ["Arts"])
        #expect(draft.feedURL == "https://feeds.example.com/new.xml")
        #expect(draft.imageURL == "https://feeds.example.com/i.jpg")
        let metadata = draft.request?.media.metadata
        #expect(metadata?.itunesID == nil && metadata?.itunesPageURL == nil && metadata?.explicit == false)
        // Without a URL in the feed, the one looked up is kept.
        #expect(makeDraft(directory: nil, feed: podcastFeed(feedURL: nil)).feedURL == "https://looked.up/feed")
    }

    @Test func blankDirectoryValuesFallBackToTheFeed() {
        let blank = PodcastDirectoryResult(title: " ", artistName: "", genres: [], feedURL: "")
        let draft = makeDraft(directory: blank)
        #expect(draft.title == "Feed Title" && draft.author == "Feed Author")
        #expect(draft.feedURL == "https://feeds.example.com/new.xml")
        // Legacy keeps the directory's genres even when empty.
        #expect(draft.genres.isEmpty)
    }

    @Test func thePathIsTheFolderAndTheSanitizedTitle() {
        let draft = makeDraft()
        // Legacy swaps the first colon for " - ", so "Show: The" keeps both spaces.
        draft.title = "Show: The Best? <Ever>"
        #expect(draft.path == "/podcasts/Show -  The Best Ever")
        draft.folderID = "f2"
        #expect(draft.path == "/mnt/more/Show -  The Best Ever")
        #expect(draft.request?.path == "/mnt/more/Show -  The Best Ever" && draft.request?.folderID == "f2")
        #expect(NewPodcastDraft.podcastPath(folder: "/", title: "A") == "/A")
        #expect(NewPodcastDraft.podcastPath(folder: "C:\\Podcasts", title: "A") == "C:\\Podcasts/A")
    }

    @Test(arguments: [
        ("Plain Title", "Plain Title"), ("a:b:c", "a - bc"), ("What? Why*|\"/\\<>", "What Why"),
        ("line\nbreak\r\ttab\u{0}", "linebreaktab"), ("c1\u{85}\u{9F}x", "c1x"), ("...", ""), ("CON", ""),
        ("lpt1.txt", ""), ("Console", "Console"), ("com10", "com10"), ("Trailing. . ", "Trailing"),
        (" Leading", " Leading"), ("Émission ☕️", "Émission ☕️"), ("a/../b", "a..b"), ("/", ""),
    ])
    func sanitizingMatchesLegacy(input: String, expected: String) {
        #expect(NewPodcastDraft.sanitizedFilename(input) == expected)
    }

    @Test func longNamesAreShortenedBeforeTheirExtension() {
        let long = String(repeating: "a", count: 250) + ".mp3"
        let sanitized = NewPodcastDraft.sanitizedFilename(long)
        #expect(sanitized.utf16.count == NewPodcastDraft.maxFilenameLength)
        #expect(sanitized == String(repeating: "a", count: 236) + ".mp3")
        let emoji = String(repeating: "🎙", count: 130)
        #expect(NewPodcastDraft.sanitizedFilename(emoji).utf16.count <= NewPodcastDraft.maxFilenameLength)
    }

    @Test func aTitleAndAFolderAreRequired() {
        let draft = makeDraft()
        #expect(draft.issues.isEmpty && draft.canSubmit && draft.request != nil)

        for title in ["", "   ", "???", "...", "/"] {
            draft.title = title
            #expect(draft.issues == [.titleMissing], "title \(title)")
            #expect(draft.path == nil && draft.request == nil && !draft.canSubmit)
        }
        draft.title = "Valid"
        draft.folderID = nil
        #expect(draft.issues == [.folderMissing] && draft.path == nil && draft.request == nil)
        draft.folderID = "not-a-folder"
        #expect(draft.issues == [.folderMissing])

        let noFolders = makeDraft(folders: [])
        #expect(noFolders.folderID == nil && noFolders.issues == [.folderMissing])
        noFolders.title = ""
        #expect(noFolders.issues == [.titleMissing, .folderMissing])
    }

    @Test func emptyValuesAreLeftOutOfTheRequest() throws {
        let draft = makeDraft()
        draft.author = "  "
        draft.description = ""
        draft.genres = ["News", ""]
        draft.autoDownloadEpisodes = true
        let request = try #require(draft.request)
        #expect(request.libraryID == "lib" && request.media.autoDownloadEpisodes)
        #expect(request.media.metadata.author == nil && request.media.metadata.description == nil)
        #expect(request.media.metadata.genres == ["News"])
    }

    @Test func submitCreatesThePodcastAndReturnsItsID() async throws {
        let draft = makeDraft()
        var calls = service.creates.calls.makeAsyncIterator()
        let submit = Task { await draft.submit() }
        let call = try #require(await calls.next())
        #expect(draft.isSubmitting && !draft.canSubmit)
        #expect(call.request == draft.request)
        // A second submit while one runs sends nothing.
        #expect(await draft.submit() == nil)
        call.reply.resume(returning: LibraryItem(id: "li-new", libraryId: "lib", mediaType: .podcast))
        #expect(await submit.value == "li-new")
        #expect(!draft.isSubmitting && draft.submitError == nil)
    }

    @Test func anInvalidFormIsNotSubmitted() async {
        let draft = makeDraft()
        draft.title = ""
        #expect(await draft.submit() == nil)
        #expect(!draft.isSubmitting && draft.submitError == nil)
    }

    @Test(arguments: [
        (APIError.http(status: 400, message: " Podcast already exists\n"), "Podcast already exists"),
        (APIError.http(status: 500, message: nil), nil), (APIError.forbidden(message: "Forbidden"), nil),
        (APIError.http(status: 403, message: "Forbidden"), nil), (APIError.http(status: 404, message: "No"), nil),
        (APIError.network(.notConnectedToInternet), nil),
    ])
    func aRefusedSubmitKeepsTheServersMessage(error: APIError, message: String?) async throws {
        let draft = makeDraft()
        var calls = service.creates.calls.makeAsyncIterator()
        let submit = Task { await draft.submit() }
        try #require(await calls.next()).reply.resume(throwing: error)
        #expect(await submit.value == nil)
        #expect(draft.submitError as? APIError == error)
        #expect(draft.submitErrorMessage == message)
        #expect(draft.canSubmit)
    }
}
