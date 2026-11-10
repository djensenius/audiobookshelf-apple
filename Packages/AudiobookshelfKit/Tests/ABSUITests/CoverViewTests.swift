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

    @Test func withoutAPipelineTheFallbackShowsInsteadOfLoading() {
        #expect(ImageFallback.resolve(hasKey: true, hasPipeline: false, failed: false) == .noImage)
        #expect(ImageFallback.resolve(hasKey: false, hasPipeline: true, failed: false) == .noImage)
        #expect(ImageFallback.resolve(hasKey: true, hasPipeline: true, failed: false) == nil)
        #expect(ImageFallback.resolve(hasKey: true, hasPipeline: true, failed: true) == .failed)
    }

    @Test func memoryHitsAppearWithoutAFade() {
        #expect(ImageReveal.animation(after: .milliseconds(2)) == nil)
        #expect(ImageReveal.animation(after: .milliseconds(400)) != nil)
    }

    @Test func voiceOverValueSpeaksProgressOrFinished() {
        let locale = Locale(identifier: "en_US")
        #expect(CoverView.accessibilityValue(progress: nil, isFinished: false, locale: locale) == "")
        #expect(
            CoverView.accessibilityValue(progress: 0.42, isFinished: false, locale: locale)
                == L10n.string("LabelProgress") + ", 42%")
        #expect(
            CoverView.accessibilityValue(progress: 0.42, isFinished: true, locale: locale)
                == L10n.string("LabelFinished"))
    }

    private struct LoadFailed: Error {}

    private func request(_ id: String) throws -> ImageLoadRequest {
        try #require(
            ImageLoadRequest(
                key: ImageKey(serverID: UUID(), kind: .itemCover, entityID: id, updatedAt: 1),
                size: CGSize(width: 100, height: 160), scale: 2))
    }

    @Test func losingThePipelineOrRequestClearsTheLoadedImage() throws {
        let cover = try request("li_1")
        var state = ImageLoadState<String>()
        let loads = state.begin(cover, hasPipeline: true)
        #expect(loads)
        state.finish(cover, result: .success("cover"), isCancelled: false)
        #expect(state.image == "cover")
        let loadsWithoutPipeline = state.begin(cover, hasPipeline: false)
        #expect(!loadsWithoutPipeline)
        #expect(state.image == nil && state.entity == nil && !state.failed)

        state.finish(cover, result: .failure(LoadFailed()), isCancelled: false)
        #expect(state.failed)
        let loadsWithoutRequest = state.begin(nil, hasPipeline: true)
        #expect(!loadsWithoutRequest)
        #expect(state.image == nil && !state.failed)
    }

    @Test func cancelledLoadsPublishNothing() throws {
        let (first, second) = (try request("li_1"), try request("li_2"))
        var state = ImageLoadState<String>()
        _ = state.begin(first, hasPipeline: true)
        state.finish(first, result: .success("first"), isCancelled: false)
        let loadsNewKey = state.begin(second, hasPipeline: true)
        #expect(loadsNewKey)
        #expect(state.image == nil)
        // The old task's memory hit resumes after the key changed.
        state.finish(first, result: .success("first"), isCancelled: true)
        state.finish(first, result: .failure(LoadFailed()), isCancelled: true)
        #expect(state.image == nil && !state.failed)
        state.finish(second, result: .success("second"), isCancelled: false)
        #expect(state.image == "second" && state.entity == "li_2")
    }

    @Test func disappearingReleasesTheImageAndReturningReloadsIt() throws {
        let cover = try request("li_1")
        var state = ImageLoadState<String>()
        _ = state.begin(cover, hasPipeline: true)
        state.finish(cover, result: .success("cover"), isCancelled: false)
        state.disappear()
        #expect(state.image == nil)
        let reloads = state.begin(cover, hasPipeline: true)
        #expect(reloads)
        state.finish(cover, result: .success("cover"), isCancelled: false)
        #expect(state.image == "cover")
    }

    @Test func sameEntityRefetchKeepsTheImageUntilTheNewOneArrives() throws {
        var state = ImageLoadState<String>()
        let small = try request("li_1")
        _ = state.begin(small, hasPipeline: true)
        state.finish(small, result: .success("small"), isCancelled: false)
        let larger = try #require(
            ImageLoadRequest(key: small.key, size: CGSize(width: 300, height: 480), scale: 2))
        let loadsLarger = state.begin(larger, hasPipeline: true)
        #expect(loadsLarger)
        #expect(state.image == "small")
    }
}
