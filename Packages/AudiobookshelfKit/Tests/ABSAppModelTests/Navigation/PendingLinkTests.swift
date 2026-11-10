import Foundation
import Testing

@testable import ABSAppModel

@Suite struct PendingLinkTests {
    private let link = DeepLink(.item(id: "li_1", episodeID: nil))

    @Test func linkIsDeliveredOnlyAtTheEpochItArrivedIn() throws {
        let pending = try #require(PendingLink(link, arrivingAt: .ready(identityA, isOffline: false), epoch: 4))

        #expect(pending.link(atEpoch: 4) == link)
        #expect(pending.link(atEpoch: 5) == nil)
        #expect(pending.link(atEpoch: 3) == nil)
    }

    @Test func linkTaggedAfterTheBumpSurvivesTheStaleOnlyClear() throws {
        // The epoch moved from 4 to 5 and a link arrived before the view rendered: it carries 5.
        let before = try #require(PendingLink(link, arrivingAt: .ready(identityA, isOffline: false), epoch: 4))
        let after = try #require(PendingLink(link, arrivingAt: .switching(from: identityA), epoch: 5))

        #expect(before.link(atEpoch: 5) == nil)
        #expect(after.link(atEpoch: 5) == link)
    }

    @Test func linkArrivesOnlyAtGatesThatHoldLinks() {
        let failure = SessionStoreError(CocoaError(.fileWriteOutOfSpace))
        let held: [AuthGate] = [.launching, .ready(identityA, isOffline: true), .switching(from: identityA)]
        for gate in held {
            #expect(PendingLink(link, arrivingAt: gate, epoch: 0) != nil, "\(gate)")
        }
        let dropped: [AuthGate] = [.signingOut(from: identityA), .connect, .storeUnavailable(failure)]
        for gate in dropped {
            #expect(PendingLink(link, arrivingAt: gate, epoch: 0) == nil, "\(gate)")
        }
    }
}
