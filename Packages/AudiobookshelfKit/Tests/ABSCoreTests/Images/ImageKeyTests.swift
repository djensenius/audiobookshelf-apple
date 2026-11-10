import CoreGraphics
import Foundation
import Testing

@testable import ABSCore

@Suite struct ImageKeyTests {
    @Test func bucketsAndPixelBoxes() {
        #expect(ImageWidthBucket(pixelWidth: 180) == .small)
        #expect(ImageWidthBucket(pixelWidth: 510) == .medium)
        #expect(ImageWidthBucket(pixelWidth: 2048) == .large)
        let box = PixelBox(size: CGSize(width: 170, height: 272), scale: 3)
        #expect(box == PixelBox(width: 512, height: 832))
        #expect(PixelBox(width: 5000, height: 1).height == 32 && PixelBox(width: 5000, height: 1).width == 1200)
    }

    @Test func fileStemIsSanitisedAndUnique() {
        let serverID = UUID()
        func stem(_ id: String, _ updatedAt: Int?, url: URL? = nil) -> String {
            ImageKey(
                serverID: serverID, kind: .authorImage, entityID: id, updatedAt: updatedAt, bucket: .small,
                externalURL: url
            ).fileStem
        }
        #expect(stem("../a/b", 42).hasPrefix("authorImage-___a_b-42-300-"))
        #expect(!stem("../a/b", 42).contains("/"))
        #expect(stem("a/b", 1) != stem("a_b", 1))
        #expect(stem("a", nil) != stem("a", 0))
        #expect(stem("a", 1, url: URL(string: "https://x.example/1.jpg")) != stem("a", 1))
        #expect(stem("a", 1) == stem("a", 1))
    }
}
