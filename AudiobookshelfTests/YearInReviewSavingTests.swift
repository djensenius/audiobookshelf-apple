import Foundation
import Synchronization
import Testing

@testable import Audiobookshelf

#if os(macOS)
    import AppKit
#endif

private struct AddFailed: Error {}

/// A photo library that records what was asked of it.
private final class FakePhotoLibrary: PhotoLibraryAdding {
    let access: Mutex<PhotoAddAccess>
    /// The access the prompt answers with.
    let answer: PhotoAddAccess
    let failsAdd: Bool
    let requests = Mutex(0)
    let added = Mutex<[Data]>([])

    init(access: PhotoAddAccess, answer: PhotoAddAccess = .denied, failsAdd: Bool = false) {
        self.access = Mutex(access)
        self.answer = answer
        self.failsAdd = failsAdd
    }

    func addAccess() -> PhotoAddAccess { access.withLock { $0 } }

    func requestAddAccess() async -> PhotoAddAccess {
        requests.withLock { $0 += 1 }
        access.withLock { $0 = answer }
        return answer
    }

    func addPNG(_ png: Data) async throws {
        if failsAdd { throw AddFailed() }
        added.withLock { $0.append(png) }
    }
}

@Suite struct YearInReviewSavingTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47])

    private func save(_ library: FakePhotoLibrary) async -> PhotoSaveOutcome {
        await YearInReviewPhotoSaver(library: library).save(png: png)
    }

    /// Granted access, now or at the first prompt, saves the image. Limited access may add too.
    @Test(arguments: [
        (PhotoAddAccess.authorized, PhotoAddAccess.denied, 0), (.limited, .denied, 0), (.notDetermined, .authorized, 1),
        (.notDetermined, .limited, 1),
    ])
    func grantedAccessSaves(access: PhotoAddAccess, answer: PhotoAddAccess, prompts: Int) async {
        let library = FakePhotoLibrary(access: access, answer: answer)
        #expect(await save(library) == .saved)
        #expect(library.added.withLock { $0 } == [png])
        #expect(library.requests.withLock { $0 } == prompts)
    }

    /// Denied or restricted access saves nothing and offers Settings; the user is asked only
    /// while undecided, never again after answering.
    @Test(arguments: [
        (PhotoAddAccess.denied, PhotoAddAccess.authorized, PhotoSaveOutcome.denied, 0),
        (.restricted, .authorized, .restricted, 0), (.notDetermined, .denied, .denied, 1),
        (.notDetermined, .restricted, .restricted, 1), (.notDetermined, .notDetermined, .denied, 1),
    ])
    func refusedAccessSavesNothing(
        access: PhotoAddAccess, answer: PhotoAddAccess, outcome: PhotoSaveOutcome, prompts: Int
    ) async {
        let library = FakePhotoLibrary(access: access, answer: answer)
        let result = await save(library)
        #expect(result == outcome)
        #expect(result.offersSettings)
        #expect(library.added.withLock { $0 }.isEmpty)
        #expect(library.requests.withLock { $0 } == prompts)
    }

    /// A failed add is reported, without sending the user to Settings. Negative control: the
    /// same library without the failure saves.
    @Test func failedAddIsReported() async {
        let failing = FakePhotoLibrary(access: .authorized, failsAdd: true)
        let result = await save(failing)
        #expect(result == .failed)
        #expect(!result.offersSettings)
        #expect(await save(FakePhotoLibrary(access: .authorized)) == .saved)
    }

    @Test func outcomesHaveDistinctMessages() {
        let outcomes: [PhotoSaveOutcome] = [.saved, .denied, .restricted, .failed]
        #expect(Set(outcomes.map(\.messageKey)).count == outcomes.count)
        #expect(!PhotoSaveOutcome.saved.offersSettings)
    }

    #if os(macOS)
        /// The image is put on the pasteboard as PNG data, replacing what was there.
        @Test func copyPutsThePNGOnThePasteboard() throws {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("YearInReviewSavingTests-\(UUID())"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.setString("old", forType: .string)
            YearInReviewClipboard.copy(png: png, to: pasteboard)
            #expect(pasteboard.data(forType: .png) == png)
            #expect(pasteboard.string(forType: .string) == nil)
        }
    #endif
}
