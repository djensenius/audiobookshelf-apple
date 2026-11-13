import Foundation
import Testing

@testable import ABSAppModel

@Suite struct EPUBTableOfContentsTests {
    private static let book = [
        EPUBTOCItem(
            id: "1", label: "Part One", href: "part1.xhtml",
            subitems: [
                EPUBTOCItem(
                    id: "1a", label: "Chapter 1", href: "ch1.xhtml",
                    subitems: [EPUBTOCItem(id: "1a1", label: "Scene", href: "ch1.xhtml#scene")]),
                EPUBTOCItem(id: "1b", label: "Chapter 2", href: "./ch2.xhtml"),
            ]),
        EPUBTOCItem(id: "2", label: "Epilogue", href: "epilogue.xhtml"),
    ]

    @Test func nestedEntriesAreListedInReadingOrderByLevel() {
        let contents = EPUBTableOfContents(Self.book)
        #expect(contents.entries.map(\.label) == ["Part One", "Chapter 1", "Scene", "Chapter 2", "Epilogue"])
        #expect(contents.entries.map(\.level) == [0, 1, 2, 1, 0])
        #expect(contents.entries.map(\.id) == Array(0..<5))
    }

    @Test func aBookWithoutContentsListsNothing() throws {
        #expect(EPUBTableOfContents([]).entries.isEmpty)
        let decoded = try #require(EPUBTableOfContents.decode(Data(#"{"type":"toc","items":[]}"#.utf8)))
        #expect(decoded.entries.isEmpty)
    }

    @Test func aTOCMessageDecodesNested() throws {
        let json = #"""
            {"type":"toc","items":[{"id":"c1","label":"One","href":"c1.xhtml",
              "subitems":[{"id":"c1a","label":"A","href":"c1.xhtml#a"}]}]}
            """#
        let decoded = try #require(EPUBTableOfContents.decode(Data(json.utf8)))
        #expect(decoded.entries.map(\.href) == ["c1.xhtml", "c1.xhtml#a"])
        #expect(decoded.entries.map(\.level) == [0, 1])
    }

    @Test(arguments: [
        #"{"type":"toc","items":[{"id":"c1","href":"c1.xhtml"}]}"#,
        #"{"type":"toc","items":{}}"#,
        #"{"type":"relocated"}"#,
        #"["toc"]"#,
        "not json",
    ])
    func aMalformedMessageGivesNoContents(json: String) {
        #expect(EPUBTableOfContents.decode(Data(json.utf8)) == nil)
    }

    @Test func anEntryWithoutAnHrefGivesWayToItsSubitems() {
        let contents = EPUBTableOfContents([
            EPUBTOCItem(
                id: "p", label: "Part", href: "", subitems: [EPUBTOCItem(id: "c", label: " ", href: "c.xhtml")])
        ])
        #expect(contents.entries == [EPUBContentsEntry(id: 0, label: "c.xhtml", href: "c.xhtml", level: 0)])
    }

    @Test func aCraftedListIsBoundedInLengthAndIndentation() {
        var deep = EPUBTOCItem(id: "leaf", label: "Leaf", href: "leaf.xhtml")
        for level in 0..<20 { deep = EPUBTOCItem(id: "\(level)", label: "L", href: "l.xhtml", subitems: [deep]) }
        #expect(EPUBTableOfContents([deep]).entries.map(\.level).max() == EPUBTableOfContents.maxLevel)

        let long = (0..<(EPUBTableOfContents.maxEntries + 10)).map {
            EPUBTOCItem(id: "\($0)", label: "C", href: "c\($0).xhtml")
        }
        #expect(EPUBTableOfContents(long).entries.count == EPUBTableOfContents.maxEntries)
    }

    @Test func theCurrentEntryIsTheFirstInTheShownSection() {
        let contents = EPUBTableOfContents(Self.book)
        #expect(contents.currentEntryID(href: "ch1.xhtml") == 1)
        #expect(contents.currentEntryID(href: "ch2.xhtml") == 3)
        #expect(contents.currentEntryID(href: "./epilogue.xhtml") == 4)
        #expect(contents.currentEntryID(href: "appendix.xhtml") == nil)
        #expect(contents.currentEntryID(href: nil) == nil)
    }
}

@MainActor
@Suite struct EPUBContentsModelTests {
    @Test func choosingAnEntryShowsItAndClosesTheSheet() throws {
        let model = EPUBContentsModel()
        model.receive(EPUBTableOfContents([EPUBTOCItem(id: "c", label: "C", href: "c.xhtml#start")]))
        model.isPresented = true

        let entry = try #require(model.contents?.entries.first)
        #expect(model.select(entry) == .display(target: "c.xhtml#start"))
        #expect(!model.isPresented)
    }

    @Test func theHighlightFollowsTheReader() {
        let model = EPUBContentsModel()
        #expect(model.currentEntryID == nil)
        model.receive(
            EPUBTableOfContents([
                EPUBTOCItem(id: "a", label: "A", href: "a.xhtml"), EPUBTOCItem(id: "b", label: "B", href: "b.xhtml"),
            ]))
        model.relocated(to: "a.xhtml")
        #expect(model.currentEntryID == 0)
        model.relocated(to: "b.xhtml")
        #expect(model.currentEntryID == 1)
    }
}

struct EPUBContentsScrollTests {
    /// The book's first location can come after the sheet is shown: the list scrolls to it then.
    @Test func aLateFirstLocationIsScrolledTo() {
        var scroll = EPUBContentsScroll()
        #expect(scroll.target(for: nil) == nil)
        #expect(scroll.target(for: 3) == 3)
    }

    /// Once it has scrolled, the reader moving on doesn't pull the list away from someone browsing.
    @Test func itScrollsOnlyOnce() {
        var scroll = EPUBContentsScroll()
        #expect(scroll.target(for: 2) == 2)
        #expect(scroll.target(for: 4) == nil)
        #expect(scroll.target(for: nil) == nil)
        #expect(scroll.target(for: 5) == nil)
    }
}
