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
    /// malformed references are kept as written; invalid code points become U+FFFD.
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
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value else { return nil }
            guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
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
        "script", "style", "template", "noscript", "iframe", "object", "svg", "math", "textarea",
        "title", "head", "select",
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

    private mutating func readName() -> String {
        var name = ""
        while index < scalars.count, isLetter(scalars[index]) || ("0"..."9").contains(scalars[index]) {
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
        case _ where Self.paragraphElements.contains(name): output.ensureBreaks(2)
        case _ where Self.lineElements.contains(name): output.ensureBreaks(1)
        case _ where Self.rawTextElements.contains(name): skipRawText(name)
        default: break
        }
    }

    private mutating func close(_ name: String) {
        switch name {
        case "b", "strong": output.bold = max(output.bold - 1, 0)
        case "i", "em": output.italic = max(output.italic - 1, 0)
        case "a": _ = output.links.popLast()
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
            if matchesCaseInsensitive(closing, at: position) {
                let after = position + closing.count
                if after >= scalars.count || isWhitespace(scalars[after]) || scalars[after] == ">"
                    || scalars[after] == "/"
                {
                    skipPast(">", from: after)
                    return
                }
            }
            position += 1
        }
        index = scalars.count
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

/// Accumulates styled text, collapsing whitespace and tracking line breaks.
private struct OutputBuilder {
    var bold = 0
    var italic = 0
    var links: [URL?] = []

    private struct List {
        var ordered: Bool
        var next = 1
    }

    private var lists: [List] = []
    private var result = AttributedString()
    private var isEmpty = true
    private var trailingNewlines = 0
    private var pendingSpace = false

    private var attributes: AttributeContainer {
        var container = AttributeContainer()
        var intent: InlinePresentationIntent = []
        if bold > 0 { intent.insert(.stronglyEmphasized) }
        if italic > 0 { intent.insert(.emphasized) }
        if !intent.isEmpty { container.inlinePresentationIntent = intent }
        if let link = links.last ?? nil { container.link = link }
        return container
    }

    mutating func appendText(_ text: String) {
        var chunk = ""
        for character in text {
            if character.isHTMLWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace, !chunk.isEmpty || (!isEmpty && trailingNewlines == 0) {
                chunk.append(" ")
            }
            pendingSpace = false
            chunk.append(character)
        }
        guard !chunk.isEmpty else { return }
        result += AttributedString(chunk, attributes: attributes)
        isEmpty = false
        trailingNewlines = 0
    }

    mutating func lineBreak() {
        pendingSpace = false
        result += AttributedString("\n")
        trailingNewlines += 1
    }

    /// Ends the current line or paragraph so that at least `count` line breaks precede the next text.
    mutating func ensureBreaks(_ count: Int) {
        pendingSpace = false
        guard !isEmpty else { return }
        while trailingNewlines < count { lineBreak() }
    }

    mutating func openList(ordered: Bool) {
        ensureBreaks(lists.isEmpty ? 2 : 1)
        lists.append(List(ordered: ordered))
    }

    mutating func closeList() {
        _ = lists.popLast()
        ensureBreaks(lists.isEmpty ? 2 : 1)
    }

    mutating func listItem() {
        ensureBreaks(1)
        let indent = String(repeating: "    ", count: max(lists.count - 1, 0))
        let marker: String
        if let last = lists.indices.last, lists[last].ordered {
            marker = "\(lists[last].next). "
            lists[last].next += 1
        } else {
            marker = "• "
        }
        result += AttributedString(indent + marker)
        isEmpty = false
        trailingNewlines = 0
        pendingSpace = false
    }

    /// The result without leading or trailing line breaks.
    mutating func finish() -> AttributedString {
        while result.characters.first == "\n" { result.characters.removeFirst() }
        while result.characters.last == "\n" { result.characters.removeLast() }
        return result
    }
}

extension Character {
    fileprivate var isHTMLWhitespace: Bool {
        self == " " || self == "\t" || self == "\n" || self == "\r" || self == "\r\n" || self == "\u{0C}"
    }
}
