import CoreGraphics
import Foundation
import Testing

@testable import ABSAppModel

@Suite struct ReaderSpreadPolicyTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let setting: ReaderSpreadSetting
        let platform: ReaderPlatform
        let sizeClass: ReaderSizeClass?
        let size: CGSize
        let hinge: CGFloat?
        let expected: ReaderSpreadLayout

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        // iOS and iPadOS: regular and wider than tall.
        Case(
            name: "iPad landscape", setting: .auto, platform: .iOS, sizeClass: .regular,
            size: CGSize(width: 1194, height: 834), hinge: nil, expected: .twoUp(gap: 0)),
        Case(
            name: "iPad portrait", setting: .auto, platform: .iOS, sizeClass: .regular,
            size: CGSize(width: 834, height: 1194), hinge: nil, expected: .single),
        Case(
            name: "iPad square split view", setting: .auto, platform: .iOS, sizeClass: .regular,
            size: CGSize(width: 700, height: 700), hinge: nil, expected: .single),
        Case(
            name: "iPad narrow landscape pane", setting: .auto, platform: .iOS, sizeClass: .regular,
            size: CGSize(width: 701, height: 700), hinge: nil, expected: .twoUp(gap: 0)),
        Case(
            name: "iPhone landscape is compact", setting: .auto, platform: .iOS, sizeClass: .compact,
            size: CGSize(width: 852, height: 393), hinge: nil, expected: .single),
        Case(
            name: "unknown size class counts as compact", setting: .auto, platform: .iOS, sizeClass: nil,
            size: CGSize(width: 1194, height: 834), hinge: nil, expected: .single),
        Case(
            name: "iPhone portrait", setting: .auto, platform: .iOS, sizeClass: .compact,
            size: CGSize(width: 393, height: 852), hinge: nil, expected: .single),
        // A spanned Duo spreads around the hinge, whatever its size class and shape.
        Case(
            name: "spanned Duo, compact", setting: .auto, platform: .iOS, sizeClass: .compact,
            size: CGSize(width: 800, height: 900), hinge: 24, expected: .twoUp(gap: 24)),
        Case(
            name: "spanned Duo, regular", setting: .auto, platform: .iOS, sizeClass: .regular,
            size: CGSize(width: 1200, height: 900), hinge: 18.5, expected: .twoUp(gap: 18.5)),
        Case(
            name: "folded Duo", setting: .auto, platform: .iOS, sizeClass: .compact,
            size: CGSize(width: 400, height: 900), hinge: nil, expected: .single),
        Case(
            name: "zero hinge isn't spanned", setting: .auto, platform: .iOS, sizeClass: .compact,
            size: CGSize(width: 800, height: 900), hinge: 0, expected: .single),
        Case(
            name: "non-finite hinge isn't spanned", setting: .auto, platform: .iOS, sizeClass: .compact,
            size: CGSize(width: 800, height: 900), hinge: .nan, expected: .single),
        Case(
            name: "spanned Duo with spread off", setting: .none, platform: .iOS, sizeClass: .compact,
            size: CGSize(width: 800, height: 900), hinge: 24, expected: .single),
        // macOS: at least 800 wide and wider than tall; size classes are ignored.
        Case(
            name: "Mac exactly 800 wide", setting: .auto, platform: .macOS, sizeClass: nil,
            size: CGSize(width: 800, height: 600), hinge: nil, expected: .twoUp(gap: 0)),
        Case(
            name: "Mac just under 800", setting: .auto, platform: .macOS, sizeClass: .regular,
            size: CGSize(width: 799.5, height: 600), hinge: nil, expected: .single),
        Case(
            name: "Mac square 800", setting: .auto, platform: .macOS, sizeClass: nil,
            size: CGSize(width: 800, height: 800), hinge: nil, expected: .single),
        Case(
            name: "Mac tall wide window", setting: .auto, platform: .macOS, sizeClass: nil,
            size: CGSize(width: 1000, height: 1200), hinge: nil, expected: .single),
        Case(
            name: "Mac wide window, compact ignored", setting: .auto, platform: .macOS, sizeClass: .compact,
            size: CGSize(width: 1400, height: 900), hinge: nil, expected: .twoUp(gap: 0)),
        Case(
            name: "Mac ignores a hinge", setting: .auto, platform: .macOS, sizeClass: nil,
            size: CGSize(width: 700, height: 600), hinge: 24, expected: .single),
        // `none` always shows one page.
        Case(
            name: "iPad landscape, spread off", setting: .none, platform: .iOS, sizeClass: .regular,
            size: CGSize(width: 1194, height: 834), hinge: nil, expected: .single),
        Case(
            name: "Mac wide, spread off", setting: .none, platform: .macOS, sizeClass: nil,
            size: CGSize(width: 1400, height: 900), hinge: nil, expected: .single),
        // A size that isn't measured yet shows one page.
        Case(
            name: "zero size", setting: .auto, platform: .macOS, sizeClass: nil, size: .zero, hinge: nil,
            expected: .single),
        Case(
            name: "spanned Duo not measured yet", setting: .auto, platform: .iOS, sizeClass: .compact, size: .zero,
            hinge: 24, expected: .single),
        Case(
            name: "spanned Duo with a non-finite size", setting: .auto, platform: .iOS, sizeClass: .compact,
            size: CGSize(width: CGFloat.nan, height: 900), hinge: 24, expected: .single),
        Case(
            name: "spanned Duo with an infinite height", setting: .auto, platform: .iOS, sizeClass: .regular,
            size: CGSize(width: 800, height: CGFloat.infinity), hinge: 24, expected: .single),
        Case(
            name: "infinite width", setting: .auto, platform: .iOS, sizeClass: .regular,
            size: CGSize(width: CGFloat.infinity, height: 800), hinge: nil, expected: .single),
    ]

    @Test(arguments: cases)
    func layout(_ testCase: Case) {
        let layout = ReaderSpreadPolicy.layout(
            setting: testCase.setting, platform: testCase.platform, sizeClass: testCase.sizeClass,
            size: testCase.size, hingeWidth: testCase.hinge)
        #expect(layout == testCase.expected)
        #expect(layout.isTwoUp == (testCase.expected != .single))
    }

    @Test func settingSpellsTheBridgeValues() {
        #expect(ReaderSpreadSetting.allCases.map(\.rawValue) == ["auto", "none"])
        #expect(ReaderSpreadPolicy.minimumMacSpreadWidth == 800)
    }
}
