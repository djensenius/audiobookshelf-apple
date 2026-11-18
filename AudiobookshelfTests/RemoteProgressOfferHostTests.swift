import ABSAppModel
import ABSCore
import ABSData
import ABSUI
import Foundation
import Testing

@testable import Audiobookshelf

/// The "Jump to latest position" alert's message shows the position in the locale's digits (#689).
@Suite struct RemoteProgressOfferHostTests {
    private let key = MediaKey(serverConnectionID: UUID(), libraryItemId: "li_1")

    @Test func arabicPositionUsesArabicIndicDigits() {
        let arabic = Locale(identifier: "ar_SA")
        let offer = RemoteProgressOffer.Pending(key: key, position: 3_723)
        #expect(
            RemoteProgressOfferHost.message(for: offer, locale: arabic)
                == L10n.string("MessageRemoteProgressOffer", "١:٠٢:٠٣", locale: arabic))
        let fromDevice = RemoteProgressOffer.Pending(key: key, position: 205, deviceDescription: "iPad")
        let message = RemoteProgressOfferHost.message(for: fromDevice, locale: arabic)
        #expect(message == L10n.string("MessageRemoteProgressOfferFromDevice", "iPad", "٣:٢٥", locale: arabic))
        // No ASCII digits are left (Foundation's `contains` can match "3:25" against "٣:٢٥").
        #expect(!message.unicodeScalars.contains { ("0"..."9").contains($0) })
    }

    @Test func englishPositionIsUnchanged() {
        let english = Locale(identifier: "en_US")
        let offer = RemoteProgressOffer.Pending(key: key, position: 205, deviceDescription: "iPad")
        #expect(
            RemoteProgressOfferHost.message(for: offer, locale: english) == "iPad is at 3:25. Jump to that position?")
    }
}
