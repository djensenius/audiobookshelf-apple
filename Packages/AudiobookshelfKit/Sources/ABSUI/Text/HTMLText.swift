import Foundation

/// Converts server HTML (item and episode descriptions) to an `AttributedString` without
/// WebKit, so it is pure, thread-safe and testable.
///
/// Supports a small safe subset: `p`, `br`, `b`/`strong`, `i`/`em`, `a` (http and https
/// links only), `ul`/`ol`/`li`, and character references. Block tags such as `div` and
/// headings become line breaks; every other tag is dropped but its text kept, except the
/// content of `script`, `style` and similar raw-text elements, which is dropped too.
public enum HTMLText {
    /// The attributed text for `html`, with whitespace collapsed as a browser would.
    public static func attributedString(from html: String) -> AttributedString {
        var parser = HTMLParser(html)
        return parser.parse()
    }

    /// The plain text for `html`, for accessibility labels and search.
    public static func plainText(from html: String) -> String {
        String(attributedString(from: html).characters)
    }

    /// `href` as a URL if it is an absolute http or https link with a host, else `nil`.
    static func safeLink(_ href: String) -> URL? {
        let trimmed = decodeEntities(href).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// Decodes named (a common subset) and numeric character references. Unknown or
    /// malformed references, and references without a trailing `;`, are kept as written;
    /// invalid code points become U+FFFD.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let afterAmp = rest.index(after: amp)
            let candidate = rest[afterAmp...].prefix(32)
            if let semicolon = candidate.firstIndex(of: ";"), let decoded = decodeReference(rest[afterAmp..<semicolon])
            {
                result.append(decoded)
                rest = rest[rest.index(after: semicolon)...]
            } else {
                result.append("&")
                rest = rest[afterAmp...]
            }
        }
        result += rest
        return result
    }

    private static func decodeReference(_ name: Substring) -> Character? {
        if name.hasPrefix("#") {
            var digits = name.dropFirst()
            var radix = 10
            if digits.first == "x" || digits.first == "X" {
                digits = digits.dropFirst()
                radix = 16
            }
            let isDigit: (Character) -> Bool = { $0.isASCII && (radix == 16 ? $0.isHexDigit : $0.isWholeNumber) }
            guard !digits.isEmpty, digits.allSatisfy(isDigit) else { return nil }
            // Overflowing references saturate to U+FFFD, as in browsers.
            guard let value = UInt32(digits, radix: radix), value != 0, let scalar = Unicode.Scalar(value) else {
                return "\u{FFFD}"
            }
            return Character(scalar)
        }
        return namedEntities[String(name)]
    }

    private static let namedEntities: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
        "rdquo": "”", "laquo": "«", "raquo": "»", "bull": "•", "middot": "·", "copy": "©",
        "reg": "®", "trade": "™", "deg": "°", "eacute": "é", "egrave": "è", "aacute": "á",
        "agrave": "à", "ouml": "ö", "uuml": "ü", "auml": "ä", "szlig": "ß", "ccedil": "ç",
    ]
}

/// A forgiving single-pass tokenizer: unclosed and misnested tags never fail, they just
/// end at the end of the input.
private struct HTMLParser {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var output = OutputBuilder()

    /// Elements whose content is not text and is dropped.
    private static let rawTextElements: Set<String> = [
        "script", "style", "noscript", "iframe",
    ]
    private static let paragraphElements: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "table",
    ]
    private static let lineElements: Set<String> = ["div", "tr", "section", "article", "header", "footer"]

    init(_ html: String) {
        scalars = Array(html.unicodeScalars)
    }

    mutating func parse() -> AttributedString {
        var textStart = 0
        while index < scalars.count {
            guard scalars[index] == "<" else {
                index += 1
                continue
            }
            let tagStart = index
            guard let tag = readMarkup() else {
                // A literal `<`, such as `a < b`.
                index = tagStart + 1
                continue
            }
            output.appendText(text(textStart..<tagStart))
            handle(tag)
            textStart = index
        }
        output.appendText(text(textStart..<scalars.count))
        return output.finish()
    }

    private func text(_ range: Range<Int>) -> String {
        guard !range.isEmpty else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[range])
        return HTMLText.decodeEntities(String(view))
    }

    // MARK: Tags

    private enum Markup {
        case open(name: String, attributes: [String: String])
        case close(name: String)
        case ignored
    }

    /// Reads markup starting at `<`. Returns `nil` (and leaves `index`) if this `<` doesn't
    /// start markup. Markup that never closes consumes the rest of the input.
    private mutating func readMarkup() -> Markup? {
        let next = index + 1
        guard next < scalars.count else { return nil }
        let first = scalars[next]
        if first == "!" {
            if matches("<!--", at: index) {
                index = find("-->", from: index + 4).map { $0 + 3 } ?? scalars.count
            } else {
                skipPast(">", from: next)
            }
            return .ignored
        }
        if first == "?" {
            skipPast(">", from: next)
            return .ignored
        }
        if first == "/" {
            guard next + 1 < scalars.count, isLetter(scalars[next + 1]) else { return nil }
            index = next + 1
            let name = readName()
            skipPast(">", from: index)
            return .close(name: name)
        }
        guard isLetter(first) else { return nil }
        index = next
        let name = readName()
        guard let attributes = readAttributes() else { return .ignored }
        return .open(name: name, attributes: attributes)
    }

    /// Reads a tag name up to whitespace, `/` or `>`, so custom and namespaced elements
    /// (`script-widget`, `svg:title`) are never mistaken for supported ones.
    private mutating func readName() -> String {
        var name = ""
        while index < scalars.count, !isWhitespace(scalars[index]), scalars[index] != "/", scalars[index] != ">" {
            name.unicodeScalars.append(scalars[index])
            index += 1
        }
        return name.lowercased()
    }

    /// Reads attributes up to and including `>`. Quoted values may contain `>`. Returns `nil`
    /// if the tag never closes.
    private mutating func readAttributes() -> [String: String]? {
        var attributes: [String: String] = [:]
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == ">" {
                index += 1
                return attributes
            }
            if isWhitespace(scalar) || scalar == "/" {
                index += 1
                continue
            }
            var name = ""
            while index < scalars.count, !isWhitespace(scalars[index]), !["=", ">", "/"].contains(scalars[index]) {
                name.unicodeScalars.append(scalars[index])
                index += 1
            }
            while index < scalars.count, isWhitespace(scalars[index]) { index += 1 }
            var value = ""
            if index < scalars.count, scalars[index] == "=" {
                index += 1
                while index < scalars.count, isWhitespace(scalars[index]) { index += 1 }
                if index < scalars.count, scalars[index] == "\"" || scalars[index] == "'" {
                    let quote = scalars[index]
                    index += 1
                    while index < scalars.count, scalars[index] != quote {
                        value.unicodeScalars.append(scalars[index])
                        index += 1
                    }
                    index += 1
                } else {
                    while index < scalars.count, !isWhitespace(scalars[index]), scalars[index] != ">" {
                        value.unicodeScalars.append(scalars[index])
                        index += 1
                    }
                }
            }
            let key = name.lowercased()
            if !key.isEmpty, attributes[key] == nil { attributes[key] = value }
        }
        // The tag never closed: like a browser, drop it and everything after it.
        index = scalars.count
        return nil
    }

    private mutating func handle(_ markup: Markup) {
        switch markup {
        case .ignored:
            break
        case .open(let name, let attributes):
            open(name, attributes: attributes)
        case .close(let name):
            close(name)
        }
    }

    private mutating func open(_ name: String, attributes: [String: String]) {
        switch name {
        case "br": output.lineBreak()
        case "b", "strong": output.bold += 1
        case "i", "em": output.italic += 1
        case "a": output.links.append(attributes["href"].flatMap(HTMLText.safeLink))
        case "ul", "ol": output.openList(ordered: name == "ol")
        case "li": output.listItem()
        case "template": skipTemplate()
        case _ where Self.paragraphElements.contains(name): output.openBlock(2)
        case _ where Self.lineElements.contains(name): output.openBlock(1)
        case _ where Self.rawTextElements.contains(name): skipRawText(name)
        default: break
        }
    }

    private mutating func close(_ name: String) {
        switch name {
        case "b", "strong": output.bold = max(output.bold - 1, 0)
        case "i", "em": output.italic = max(output.italic - 1, 0)
        case "a": _ = output.links.popLast()
        case "br": output.lineBreak()
        case "ul", "ol": output.closeList()
        case "li": output.ensureBreaks(1)
        case _ where Self.paragraphElements.contains(name): output.ensureBreaks(2)
        case _ where Self.lineElements.contains(name): output.ensureBreaks(1)
        default: break
        }
    }

    /// Skips to after `</name…>`, or to the end if the element never closes.
    private mutating func skipRawText(_ name: String) {
        let closing = Array("</\(name)".unicodeScalars)
        var position = index
        while position < scalars.count {
            if matchesTag(closing, at: position) {
                skipPast(">", from: position + closing.count)
                return
            }
            position += 1
        }
        index = scalars.count
    }

    /// Skips to after the matching `</template>`, counting nested templates. Whole tags
    /// (including quoted attribute values) and comments are stepped over, so `<template>`
    /// inside an attribute or comment doesn't count. An unclosed template, tag or comment
    /// drops the rest of the input.
    private mutating func skipTemplate() {
        var depth = 1
        while index < scalars.count {
            guard scalars[index] == "<" else {
                index += 1
                continue
            }
            let start = index
            if matches("<!--", at: start) {
                guard let end = find("-->", from: start + 4) else { break }
                index = end + 3
            } else if start + 2 < scalars.count, scalars[start + 1] == "/", isLetter(scalars[start + 2]) {
                index = start + 2
                let name = readName()
                skipPast(">", from: index)
                if name == "template" {
                    depth -= 1
                    if depth == 0 { return }
                }
            } else if start + 1 < scalars.count, isLetter(scalars[start + 1]) {
                index = start + 1
                let name = readName()
                guard readAttributes() != nil else { break }
                if name == "template" {
                    depth += 1
                } else if Self.rawTextElements.contains(name) {
                    // Raw-text bodies aren't markup: `"</template>"` in a script is just text.
                    skipRawText(name)
                }
            } else {
                index = start + 1
            }
        }
        index = scalars.count
    }

    /// Whether `tag` (such as `</script`) is at `position` and its name ends there.
    private func matchesTag(_ tag: [Unicode.Scalar], at position: Int) -> Bool {
        guard matchesCaseInsensitive(tag, at: position) else { return false }
        let after = position + tag.count
        return after >= scalars.count || isWhitespace(scalars[after]) || scalars[after] == ">" || scalars[after] == "/"
    }

    // MARK: Scanning helpers

    private mutating func skipPast(_ scalar: Unicode.Scalar, from start: Int) {
        var position = start
        while position < scalars.count, scalars[position] != scalar { position += 1 }
        index = min(position + 1, scalars.count)
    }

    private func matches(_ string: String, at position: Int) -> Bool {
        matchesCaseInsensitive(Array(string.unicodeScalars), at: position)
    }

    private func find(_ string: String, from start: Int) -> Int? {
        let needle = Array(string.unicodeScalars)
        var position = start
        while position + needle.count <= scalars.count {
            if matchesCaseInsensitive(needle, at: position) { return position }
            position += 1
        }
        return nil
    }

    private func matchesCaseInsensitive(_ needle: [Unicode.Scalar], at position: Int) -> Bool {
        guard position + needle.count <= scalars.count else { return false }
        for (offset, scalar) in needle.enumerated() where lowercase(scalars[position + offset]) != lowercase(scalar) {
            return false
        }
        return true
    }

    private func lowercase(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar
    }

    private func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}"
    }
}

/// Accumulates plain text plus a list of styled runs, then builds the `AttributedString`
/// once in ``finish()``, so the cost stays linear in the input size.
private struct OutputBuilder {
    var bold = 0
    var italic = 0
    var links: [URL?] = []

    private struct List {
        var ordered: Bool
        var next = 1
    }

    private struct Style: Equatable {
        var bold = false
        var italic = false
        var link: URL?
    }

    /// Deeper lists are flattened into the deepest one, so hostile nesting can't blow up the output.
    private static let maxListDepth = 16
    /// Indentation stops growing after this many levels.
    private static let maxIndentLevel = 3

    private var lists: [List] = []
    private var flattenedLists = 0
    private var text = ""
    private var runs: [(scalarCount: Int, style: Style)] = []
    private var isEmpty = true
    private var atLineStart = true
    private var trailingNewlines = 0
    private var pendingSpace = false
    private var pendingBreaks = 0
    private var listJustOpened = false

    private var style: Style {
        Style(bold: bold > 0, italic: italic > 0, link: links.last ?? nil)
    }

    private mutating func append(_ string: String, style: Style = Style()) {
        guard !string.isEmpty else { return }
        text += string
        let count = string.unicodeScalars.count
        if let last = runs.indices.last, runs[last].style == style {
            runs[last].scalarCount += count
        } else {
            runs.append((count, style))
        }
    }

    mutating func appendText(_ text: String) {
        var chunk = ""
        for character in text {
            if character.isHTMLWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace, !chunk.isEmpty || (!isEmpty && !atLineStart && pendingBreaks == 0) {
                chunk.append(" ")
            }
            pendingSpace = false
            chunk.append(character)
        }
        guard !chunk.isEmpty else { return }
        flushBreaks()
        append(chunk, style: style)
        isEmpty = false
        atLineStart = false
        trailingNewlines = 0
    }

    /// A line break; ignored before any text, so the result never starts with one.
    mutating func lineBreak() {
        pendingSpace = false
        guard !isEmpty else { return }
        flushBreaks()
        appendNewline()
    }

    /// Ends the current line or paragraph so that at least `count` line breaks precede the
    /// next text. Breaks are written lazily, so a list item can cap them.
    mutating func ensureBreaks(_ count: Int) {
        pendingSpace = false
        pendingBreaks = max(pendingBreaks, count)
    }

    /// Opens a block element. Right after a list marker the break is skipped, so
    /// `<li><p>One</p></li>` renders `• One`.
    mutating func openBlock(_ count: Int) {
        if !isEmpty, atLineStart, trailingNewlines == 0, pendingBreaks == 0 {
            pendingSpace = false
            return
        }
        ensureBreaks(count)
    }

    mutating func openList(ordered: Bool) {
        ensureBreaks(lists.isEmpty ? 2 : 1)
        listJustOpened = true
        if lists.count < Self.maxListDepth {
            lists.append(List(ordered: ordered))
        } else {
            flattenedLists += 1
        }
    }

    mutating func closeList() {
        if flattenedLists > 0 {
            flattenedLists -= 1
        } else {
            _ = lists.popLast()
        }
        ensureBreaks(lists.isEmpty ? 2 : 1)
    }

    mutating func listItem() {
        // Items are on consecutive lines even if the previous one ended with a paragraph;
        // the first item keeps the break before its list.
        pendingSpace = false
        pendingBreaks = listJustOpened ? max(pendingBreaks, 1) : 1
        flushBreaks()
        let indent = String(repeating: "    ", count: min(max(lists.count - 1, 0), Self.maxIndentLevel))
        let marker: String
        if let last = lists.indices.last, lists[last].ordered {
            marker = "\(lists[last].next). "
            lists[last].next += 1
        } else {
            marker = "• "
        }
        append(indent + marker)
        isEmpty = false
        atLineStart = true
        trailingNewlines = 0
    }

    private mutating func flushBreaks() {
        defer {
            pendingBreaks = 0
            listJustOpened = false
        }
        guard !isEmpty else { return }
        while trailingNewlines < pendingBreaks { appendNewline() }
    }

    private mutating func appendNewline() {
        // A bare list marker keeps no trailing space.
        if atLineStart, trailingNewlines == 0, text.unicodeScalars.last == " ", let last = runs.indices.last {
            text.unicodeScalars.removeLast()
            runs[last].scalarCount -= 1
            if runs[last].scalarCount == 0 { runs.removeLast() }
        }
        append("\n")
        trailingNewlines += 1
        atLineStart = true
    }

    /// The result without trailing line breaks or spaces.
    mutating func finish() -> AttributedString {
        var trimmed = 0
        while let last = text.unicodeScalars.last, last == "\n" || last == " " {
            text.unicodeScalars.removeLast()
            trimmed += 1
        }
        while trimmed > 0, let last = runs.indices.last {
            let removed = min(trimmed, runs[last].scalarCount)
            runs[last].scalarCount -= removed
            trimmed -= removed
            if runs[last].scalarCount == 0 { runs.removeLast() }
        }

        var result = AttributedString(text)
        var start = result.startIndex
        for run in runs {
            let end = result.unicodeScalars.index(start, offsetBy: run.scalarCount)
            if run.style != Style() {
                var container = AttributeContainer()
                var intent: InlinePresentationIntent = []
                if run.style.bold { intent.insert(.stronglyEmphasized) }
                if run.style.italic { intent.insert(.emphasized) }
                if !intent.isEmpty { container.inlinePresentationIntent = intent }
                if let link = run.style.link { container.link = link }
                result[start..<end].mergeAttributes(container)
            }
            start = end
        }
        return result
    }
}

extension Character {
    fileprivate var isHTMLWhitespace: Bool {
        self == " " || self == "\t" || self == "\n" || self == "\r" || self == "\r\n" || self == "\u{0C}"
    }
}
