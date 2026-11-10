import Foundation
import Testing

@testable import ABSUI

@Suite struct HTMLTextTests {
    private func plain(_ html: String) -> String { HTMLText.plainText(from: html) }

    private func links(_ html: String) -> [URL] {
        HTMLText.attributedString(from: html).runs.compactMap(\.link)
    }

    private func intent(of substring: String, in html: String) throws -> InlinePresentationIntent? {
        let value = HTMLText.attributedString(from: html)
        let range = try #require(value.range(of: substring))
        let intents = Set(value[range].runs.map(\.inlinePresentationIntent))
        #expect(intents.count == 1)
        return intents.first ?? nil
    }

    // MARK: Text and whitespace

    @Test func plainTextPassesThrough() {
        #expect(plain("Hello, world") == "Hello, world")
        #expect(plain("") == "")
    }

    @Test func collapsesWhitespace() {
        #expect(plain("  a \n\t b   c  ") == "a b c")
        #expect(plain("<p>  one\n  two </p>") == "one two")
    }

    @Test func keepsSpacesAcrossInlineTags() {
        #expect(plain("a <b>b</b> c") == "a b c")
        #expect(plain("<b>a</b><i>b</i>") == "ab")
    }

    // MARK: Blocks

    @Test func paragraphsAreSeparatedByBlankLine() {
        #expect(plain("<p>One</p><p>Two</p>") == "One\n\nTwo")
        #expect(plain("<p>One</p>\n\n<p>Two</p>\n") == "One\n\nTwo")
    }

    @Test func lineBreaks() {
        #expect(plain("a<br>b<br/>c<BR />d</br>e") == "a\nb\nc\nd\ne")
        #expect(plain("<br><br>a<br>") == "a")
    }

    @Test func divsAndHeadingsBreakLines() {
        #expect(plain("<div>a</div><div>b</div>") == "a\nb")
        #expect(plain("<h2>Title</h2>Body") == "Title\n\nBody")
    }

    @Test func unorderedList() {
        #expect(plain("<p>Intro</p><ul><li>One</li><li>Two</li></ul><p>End</p>") == "Intro\n\n• One\n• Two\n\nEnd")
    }

    @Test func listItemWhitespaceIsCollapsed() {
        #expect(plain("<ul>\n<li>\n  A\n</li></ul>") == "• A")
        #expect(plain("<ol>\n  <li>  A  </li>\n  <li>\tB</li>\n</ol>") == "1. A\n2. B")
        #expect(plain("<ul><li></li></ul>") == "•")
    }

    @Test func blocksInsideListItemsStayOnTheMarkerLine() {
        let html = "<ul><li><p>One</p></li><li><p>Two</p><p>More</p></li></ul>"
        #expect(plain(html) == "• One\n• Two\n\nMore")
        #expect(plain("<ul><li><div>x</div></li></ul>") == "• x")
        #expect(plain("<ul><li><h3>x</h3></li></ul>") == "• x")
        #expect(plain("<ol><li><p>A</p></li><li><div>B</div></li></ol><p>End</p>") == "1. A\n2. B\n\nEnd")
        #expect(plain("<ul><li><ul><li>x</li></ul></li></ul>") == "•\n    • x")
    }

    @Test func orderedList() {
        #expect(plain("<ol><li>One<li>Two</ol>") == "1. One\n2. Two")
    }

    @Test func nestedLists() {
        let html = "<ul><li>A<ol><li>x</li><li>y</li></ol></li><li>B</li></ul>"
        #expect(plain(html) == "• A\n    1. x\n    2. y\n• B")
    }

    @Test func deepNestingIsBounded() {
        let depth = 10_000
        let value = plain(String(repeating: "<ul><li>x", count: depth))
        // At most 3 indent levels (12 spaces) + "• x\n" per item.
        #expect(value.count <= depth * 16)
        #expect(value.hasSuffix("            • x"))
        let deepOrdered = plain(
            String(repeating: "<ol><li>x", count: 100) + String(repeating: "</ol>", count: 100) + "end")
        #expect(deepOrdered.hasSuffix("x\n\nend"))
    }

    @Test func largeInputsStayFast() {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(plain(String(repeating: "<br>", count: 100_000) + "a") == "a")
            #expect(plain("a" + String(repeating: "<br>", count: 100_000) + "b").count == 100_002)
            let styled = HTMLText.attributedString(from: String(repeating: "<b>a</b><i>b</i> ", count: 20_000))
            #expect(styled.characters.count == 60_000 - 1)
        }
        // Linear work takes well under a second; the old quadratic builder took tens of seconds.
        #expect(elapsed < .seconds(15))
    }

    // MARK: Inline styles

    @Test func boldAndStrong() throws {
        #expect(try intent(of: "bold", in: "a <b>bold</b> c") == .stronglyEmphasized)
        #expect(try intent(of: "strong", in: "a <STRONG>strong</STRONG> c") == .stronglyEmphasized)
        #expect(try intent(of: "c", in: "a <b>bold</b> c") == nil)
    }

    @Test func italicAndEm() throws {
        #expect(try intent(of: "it", in: "<i>it</i>") == .emphasized)
        #expect(try intent(of: "em", in: "<em>em</em>") == .emphasized)
    }

    @Test func nestedStyles() throws {
        let html = "<b>bold <i>both</i></b> <i>italic</i>"
        #expect(try intent(of: "both", in: html) == [.stronglyEmphasized, .emphasized])
        #expect(try intent(of: "italic", in: html) == .emphasized)
    }

    @Test func misnestedAndUnclosedStyles() throws {
        #expect(try intent(of: "rest", in: "<b>rest of text") == .stronglyEmphasized)
        #expect(plain("</b>stray</i> close") == "stray close")
        #expect(try intent(of: "after", in: "</b></b><b>x</b> after") == nil)
    }

    // MARK: Links

    @Test func httpAndHttpsLinks() {
        #expect(
            links(#"<a href="https://example.com/a?b=1&amp;c=2">x</a>"#) == [
                URL(string: "https://example.com/a?b=1&c=2")
            ])
        #expect(links("<a href='http://example.com'>x</a>") == [URL(string: "http://example.com")])
        #expect(links("<a href=https://example.com>x</a>") == [URL(string: "https://example.com")])
        #expect(links(#"<a href="  HTTPS://Example.com  ">x</a>"#).count == 1)
    }

    @Test func linkTextIsKept() {
        #expect(plain(#"see <a href="https://example.com">here</a>."#) == "see here.")
    }

    @Test func unsafeLinksAreDropped() {
        let unsafe = [
            #"<a href="javascript:alert(1)">x</a>"#,
            #"<a href="JaVaScRiPt:alert(1)">x</a>"#,
            #"<a href=" javascript:alert(1)">x</a>"#,
            #"<a href="&#106;avascript:alert(1)">x</a>"#,
            #"<a href="java&#x09;script:alert(1)">x</a>"#,
            #"<a href="java&#x0A;script:alert(1)">x</a>"#,
            #"<a href="https:evil.com">x</a>"#,
            #"<a href="https:\\evil.com">x</a>"#,
            #"<a href="data:text/html,<script>alert(1)</script>">x</a>"#,
            #"<a href="vbscript:msgbox">x</a>"#,
            #"<a href="file:///etc/passwd">x</a>"#,
            #"<a href="/relative/path">x</a>"#,
            #"<a href="//example.com">x</a>"#,
            #"<a href="https://">x</a>"#,
            #"<a>x</a>"#,
        ]
        for html in unsafe {
            #expect(links(html).isEmpty, "\(html)")
            #expect(plain(html) == "x", "\(html)")
        }
    }

    @Test func nestedUnsafeLinkDoesNotInheritOuterLink() {
        let html = #"<a href="https://ok.example">ok <a href="javascript:x">bad</a></a> after"#
        let value = HTMLText.attributedString(from: html)
        let bad = value.range(of: "bad").map { value[$0].runs.compactMap(\.link) }
        #expect(bad == [])
        #expect(value.range(of: "after").map { value[$0].runs.compactMap(\.link) } == [])
    }

    @Test func attributeValueMayContainAngleBracket() {
        #expect(links(#"<a title="a>b" href="https://example.com">x</a>"#) == [URL(string: "https://example.com")])
        #expect(plain(#"<a title="a>b" href="https://example.com">x</a>"#) == "x")
    }

    // MARK: Dropped content

    @Test func scriptAndStyleContentIsDropped() {
        #expect(plain("a<script>alert('<b>x</b>')</script>b") == "ab")
        #expect(plain("a<SCRIPT type=text/javascript>alert(1)</SCRIPT >b") == "ab")
        #expect(plain("a<style>p { color: red }</style>b") == "ab")
        #expect(plain("a<noscript>no</noscript><iframe src=x>frame</iframe>b") == "ab")
    }

    @Test func customAndNamespacedElementsKeepTheirText() {
        #expect(plain("<script-widget>description</script-widget>after") == "descriptionafter")
        #expect(plain("<svg:title>x</svg:title> y") == "x y")
        #expect(plain("<my-p>a</my-p>b") == "ab")
        #expect(plain("<b-x>plain</b-x>") == "plain")
        #expect(
            HTMLText.attributedString(from: "<b-x>plain</b-x>").runs.allSatisfy { $0.inlinePresentationIntent == nil })
        #expect(plain("<template-x>t</template-x>u") == "tu")
    }

    @Test func nestedTemplatesAreSkipped() {
        #expect(plain("before<template><template>inner</template>hidden</template>after") == "beforeafter")
        #expect(plain("before<template><!-- </template> -->hidden</template>after") == "beforeafter")
        #expect(plain("a<TEMPLATE id=t><Template>x</template>still hidden") == "a")
        #expect(plain("a<template>x<!-- never closed") == "a")
    }

    @Test func otherElementsKeepTheirText() {
        #expect(plain("<title>T</title> <textarea>x</textarea> <select>y") == "T x y")
        #expect(plain("<svg><text>s</text></svg> <object>o</object> <head>h</head>") == "s o h")
    }

    @Test func scriptClosingTagMustMatchName() {
        #expect(plain("a<script>x</scripty>y</script>b") == "ab")
    }

    @Test func unclosedScriptDropsRest() {
        #expect(plain("safe<script>alert(1)") == "safe")
    }

    @Test func unknownTagsAreStrippedButTextKept() {
        #expect(plain(#"<span class="x">hi</span> <font color=red>there</font>"#) == "hi there")
        #expect(plain(#"a<img src=x onerror="alert(1)">b"#) == "ab")
        #expect(plain(#"<div onclick="alert(1)">x</div>"#) == "x")
    }

    @Test func commentsAndDoctypeAreDropped() {
        #expect(plain("<!DOCTYPE html>a<!-- <b>hidden</b> -->b<?xml x?>c") == "abc")
        #expect(plain("a<!-- never closed") == "a")
    }

    @Test func unclosedTagDropsRest() {
        #expect(plain("text <b") == "text")
        #expect(plain(#"text <a href="https://x.com>more"#) == "text")
    }

    @Test func literalAngleBrackets() {
        #expect(plain("1 < 2 and 3 > 2") == "1 < 2 and 3 > 2")
        #expect(plain("a <3 b") == "a <3 b")
        #expect(plain("a </ b") == "a </ b")
    }

    // MARK: Entities

    @Test func namedEntities() {
        #expect(plain("&amp; &lt; &gt; &quot; &apos; &hellip; &mdash;") == "& < > \" ' … —")
        #expect(plain("a&nbsp;b") == "a\u{00A0}b")
    }

    @Test func numericEntities() {
        #expect(plain("&#39;&#x27;&#X41;&#128512;") == "''A😀")
    }

    @Test func invalidNumericEntitiesBecomeReplacementCharacter() {
        #expect(plain("&#0;&#xD800;&#x110000;") == "\u{FFFD}\u{FFFD}\u{FFFD}")
        #expect(plain("&#99999999999;&#xFFFFFFFFFF;") == "\u{FFFD}\u{FFFD}")
    }

    @Test func numericEntitiesRequireDigits() {
        #expect(plain("&#+65;&#-65;&#x+41;&#;&#x;&#٣;") == "&#+65;&#-65;&#x+41;&#;&#x;&#٣;")
    }

    @Test func unknownOrMalformedEntitiesAreKept() {
        #expect(plain("&foo; &amp &#xZZ; AT&T") == "&foo; &amp &#xZZ; AT&T")
        // References without `;` are not decoded.
        #expect(plain("&lt b &#65 c") == "&lt b &#65 c")
    }

    @Test func escapedMarkupStaysText() {
        let value = HTMLText.attributedString(from: "&lt;b&gt;not bold&lt;/b&gt; &lt;script&gt;")
        #expect(String(value.characters) == "<b>not bold</b> <script>")
        #expect(value.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }
}
