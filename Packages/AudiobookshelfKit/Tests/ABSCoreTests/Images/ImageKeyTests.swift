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
        let huge = PixelBox(width: .greatestFiniteMagnitude, height: -.greatestFiniteMagnitude)
        #expect(huge == PixelBox(width: 1200, height: 32))
        #expect(PixelBox(width: .infinity, height: .nan) == PixelBox(width: 32, height: 32))
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

    @Test(arguments: [
        String(repeating: "a" + String(repeating: "\u{0301}", count: 500), count: 4),
        String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: 200),
        String(repeating: "\u{8C37}\u{6B4C}\u{6F22}\u{5B57}", count: 300),
    ])
    func unicodeIDsGiveShortASCIIStems(_ entityID: String) {
        let stem = ImageKey(
            serverID: UUID(), kind: .itemCover, entityID: entityID, updatedAt: nil, bucket: .large
        ).fileStem
        #expect(stem.utf8.count <= 128)
        let isASCII = stem.unicodeScalars.allSatisfy(\.isASCII)
        #expect(isASCII)
        let idSegment = stem.split(separator: "-").dropFirst().first ?? ""
        #expect(idSegment.utf8.count == 64)
    }
}
