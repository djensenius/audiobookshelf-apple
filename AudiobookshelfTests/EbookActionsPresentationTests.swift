import ABSAppModel
import ABSUI
import Testing

@testable import Audiobookshelf

@MainActor
@Suite struct EbookActionsPresentationTests {
    @Test func sentShowsAndAnnouncesDevice() throws {
        let feedback = try #require(EbookActionsPresentation.feedback(for: .sent(deviceName: "Kindle")))
        let text = L10n.string("MessageItemDetailEbookSent", "Kindle")
        #expect(text.contains("Kindle"))
        #expect(feedback.alertTitle == text)
        #expect(feedback.alertMessage == nil)
        #expect(feedback.announcement == text)
    }

    @Test func sendFailureShowsServerText() throws {
        let feedback = try #require(
            EbookActionsPresentation.feedback(for: .sendFailed(deviceName: "Kindle", message: "Invalid login")))
        let title = L10n.string("MessageItemDetailEbookSendFailed", "Kindle")
        #expect(feedback.alertTitle == title)
        #expect(feedback.alertMessage == "Invalid login")
        #expect(feedback.announcement == "\(title) Invalid login")
    }

    @Test func failureWithoutServerTextAnnouncesTitle() throws {
        let feedback = try #require(EbookActionsPresentation.feedback(for: .statusChangeFailed(message: nil)))
        let title = L10n.string("MessageItemDetailEbookStatusFailed")
        #expect(feedback.alertTitle == title)
        #expect(feedback.alertMessage == nil)
        #expect(feedback.announcement == title)
    }

    @Test func statusChangeIsOnlyAnnounced() throws {
        let change = EbookActionsModel.StatusChange(id: "42", filename: "b.epub", makesPrimary: true)
        let feedback = try #require(EbookActionsPresentation.feedback(for: .statusChanged(change)))
        #expect(feedback.alertTitle == nil)
        #expect(feedback.announcement == L10n.string("MessageItemDetailEbookNowPrimary", "b.epub"))

        let unnamed = EbookActionsModel.StatusChange(id: "42", filename: "", makesPrimary: false)
        let fallback = try #require(EbookActionsPresentation.feedback(for: .statusChanged(unnamed)))
        #expect(
            fallback.announcement
                == L10n.string("MessageItemDetailEbookNowSupplementary", L10n.string("LabelEbook")))
    }

    @Test func ignoredShowsNothing() {
        #expect(EbookActionsPresentation.feedback(for: .ignored) == nil)
    }

    /// Every key the ebook entries use resolves (not echoed back as the key).
    @Test func keysResolve() {
        for key in [
            "ButtonSendEbookToDevice", "LabelSelectADevice", "LabelSetEbookAsPrimary", "LabelSetEbookAsSupplementary",
            "MessageItemDetailEbookSent", "MessageItemDetailEbookSendFailed", "MessageItemDetailEbookStatusFailed",
            "MessageItemDetailEbookNowPrimary", "MessageItemDetailEbookNowSupplementary",
        ] {
            #expect(L10n.string(key) != key, "\(key)")
        }
    }
}
