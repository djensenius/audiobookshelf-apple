import ABSCore
import CoreGraphics
import Foundation
import Testing

@testable import ABSUI

@Suite struct CoverViewTests {
    private let key = ImageKey(serverID: UUID(), kind: .itemCover, entityID: "li_1", updatedAt: 1, bucket: .large)

    @Test func loadRequestPicksTheBucketFromRenderedPixels() throws {
        let grid = try #require(ImageLoadRequest(key: key, size: CGSize(width: 170, height: 272), scale: 3))
        #expect(grid.key.bucket == .medium)
        #expect(grid.box == PixelBox(width: 512, height: 832))

        let row = try #require(ImageLoadRequest(key: key, size: CGSize(width: 60, height: 96), scale: 2))
        #expect(row.key.bucket == .small)

        let player = try #require(ImageLoadRequest(key: key, size: CGSize(width: 500, height: 500), scale: 3))
        #expect(player.key.bucket == .large)
        #expect(player.box == PixelBox(width: 1200, height: 1200))
    }

    @Test func noRequestBeforeLayoutOrWithoutAKey() {
        #expect(ImageLoadRequest(key: key, size: .zero, scale: 2) == nil)
        #expect(ImageLoadRequest(key: nil, size: CGSize(width: 100, height: 160), scale: 2) == nil)
    }

    @Test func coverShapes() {
        #expect(CoverShape.book.aspectRatio == 1.6)
        #expect(CoverShape.square.aspectRatio == 1)
    }

    @Test func groupCoverLayoutFansCoversAcrossTheFrame() {
        let size = CGSize(width: 240, height: 160)
        let single = GroupCoverView.layout(count: 1, size: size, aspectRatio: 1.6)
        #expect(single.coverWidth == 240 && single.step == 0)
        let four = GroupCoverView.layout(count: 4, size: size, aspectRatio: 1.6)
        #expect(four.coverWidth == 100)
        #expect(four.coverWidth + four.step * 3 == 240)
    }
}
