import CoreGraphics
import Testing

@testable import ABSAppModel

@Suite struct ReaderHingeTests {
    private let readerWidth: CGFloat = 800

    @Test func noRegionsIsNotSpanned() {
        #expect(ReaderHinge.width(readerWidth: readerWidth, divisions: []) == nil)
    }

    @Test func activeVerticalDivisionGivesItsWidth() {
        let hinge = CGRect(x: 388, y: 0, width: 24, height: 900)
        #expect(ReaderHinge.width(readerWidth: readerWidth, divisions: [(hinge, true)]) == 24)
    }

    @Test func zeroWidthDivisionGivesTheMinimum() {
        let hinge = CGRect(x: 400, y: 0, width: 0, height: 900)
        #expect(ReaderHinge.width(readerWidth: readerWidth, divisions: [(hinge, true)]) == ReaderHinge.minimumGap)
        #expect(ReaderHinge.minimumGap == 32)
    }

    @Test func inactiveDivisionIsIgnored() {
        let hinge = CGRect(x: 388, y: 0, width: 24, height: 900)
        #expect(ReaderHinge.width(readerWidth: readerWidth, divisions: [(hinge, false)]) == nil)
    }

    @Test func horizontalDivisionIsIgnored() {
        let hinge = CGRect(x: 0, y: 438, width: 800, height: 24)
        #expect(ReaderHinge.width(readerWidth: readerWidth, divisions: [(hinge, true)]) == nil)
    }

    @Test func divisionOutsideTheReaderIsIgnored() {
        let hinge = CGRect(x: 900, y: 0, width: 24, height: 900)
        #expect(ReaderHinge.width(readerWidth: readerWidth, divisions: [(hinge, true)]) == nil)
    }

    @Test func firstActiveVerticalDivisionCounts() {
        let divisions: [(frame: CGRect, isActive: Bool)] = [
            (CGRect(x: 300, y: 0, width: 10, height: 900), false),
            (CGRect(x: 0, y: 438, width: 800, height: 24), true),
            (CGRect(x: 390, y: 0, width: 20, height: 900), true),
        ]
        #expect(ReaderHinge.width(readerWidth: readerWidth, divisions: divisions) == 20)
    }

    @Test(arguments: [CGFloat(24), 0])
    func policySpreadsWithTheHingeGap(regionWidth: CGFloat) {
        let hinge = CGRect(x: 400 - regionWidth / 2, y: 0, width: regionWidth, height: 900)
        let width = ReaderHinge.width(readerWidth: readerWidth, divisions: [(hinge, true)])
        let layout = ReaderSpreadPolicy.layout(
            setting: .auto, platform: .iOS, sizeClass: .compact, size: CGSize(width: readerWidth, height: 900),
            hingeWidth: width)
        #expect(layout == .twoUp(gap: regionWidth > 0 ? regionWidth : ReaderHinge.minimumGap))
    }

    @Test func policyWithoutAHingeShowsOnePage() {
        let hinge = CGRect(x: 388, y: 0, width: 24, height: 900)
        let width = ReaderHinge.width(readerWidth: readerWidth, divisions: [(hinge, false)])
        let layout = ReaderSpreadPolicy.layout(
            setting: .auto, platform: .iOS, sizeClass: .compact, size: CGSize(width: readerWidth, height: 900),
            hingeWidth: width)
        #expect(layout == .single)
    }
}
