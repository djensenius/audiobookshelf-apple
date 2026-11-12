/// Blanks out the comments (and, if asked, the string literals' text) in Swift source for
/// ``SourceScanner``: enough of Swift's lexical structure to tell comments from string literals,
/// not a parser.
enum SourceLexer {
    private enum Context {
        /// Top-level code.
        case code
        /// Code in a string interpolation, `\(…)`, with its open parentheses.
        case interpolation(depth: Int)
        /// A string literal: `"…"` or `"""…"""`, raw with `pounds` `#`s.
        case string(multiline: Bool, pounds: Int)
    }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let pound = UInt8(ascii: "#")
    private static let slash = UInt8(ascii: "/")
    private static let star = UInt8(ascii: "*")
    private static let newline = UInt8(ascii: "\n")
    private static let space = UInt8(ascii: " ")

    /// `source` (UTF-8) with each comment byte replaced by a space, except newlines, so offsets
    /// and line numbers are unchanged. Comments are `//` to the end of the line and `/* … */`,
    /// nested; neither starts inside a string literal. A single-line string ends at its line even
    /// if unterminated, so a misread (a quote in a regex literal) doesn't spread past it.
    ///
    /// With `strings`, the text of string literals is blanked too (their quotes and
    /// interpolated code are kept), so a brace or `#` in a string isn't taken for code.
    static func blankingComments(_ source: [UInt8], strings: Bool = false) -> [UInt8] {
        var bytes = source
        var stack: [Context] = [.code]
        var index = 0

        func at(_ offset: Int, is byte: UInt8) -> Bool {
            offset < bytes.count && bytes[offset] == byte
        }
        func isTripleQuote(_ offset: Int) -> Bool {
            at(offset, is: quote) && at(offset + 1, is: quote) && at(offset + 2, is: quote)
        }
        func pounds(from offset: Int) -> Int {
            var count = 0
            while at(offset + count, is: pound) { count += 1 }
            return count
        }
        func blank(_ range: Range<Int>) {
            for offset in range where bytes[offset] != newline { bytes[offset] = space }
        }

        while index < bytes.count {
            switch stack[stack.count - 1] {
            case .code, .interpolation:
                let byte = bytes[index]
                if byte == slash, at(index + 1, is: slash) {
                    var end = index
                    while end < bytes.count, bytes[end] != newline { end += 1 }
                    blank(index..<end)
                    index = end
                } else if byte == slash, at(index + 1, is: star) {
                    var depth = 1
                    var end = index + 2
                    while end < bytes.count, depth > 0 {
                        if bytes[end] == slash, at(end + 1, is: star) {
                            depth += 1
                            end += 2
                        } else if bytes[end] == star, at(end + 1, is: slash) {
                            depth -= 1
                            end += 2
                        } else {
                            end += 1
                        }
                    }
                    blank(index..<end)
                    index = end
                } else if byte == quote || byte == pound {
                    let count = pounds(from: index)
                    let start = index + count
                    guard at(start, is: quote) else {
                        index = start
                        continue
                    }
                    let multiline = isTripleQuote(start)
                    stack.append(.string(multiline: multiline, pounds: count))
                    index = start + (multiline ? 3 : 1)
                } else if case .interpolation(let depth) = stack[stack.count - 1],
                    byte == UInt8(ascii: "(")
                        || byte == UInt8(ascii: ")")
                {
                    let next = depth + (byte == UInt8(ascii: "(") ? 1 : -1)
                    stack.removeLast()
                    if next > 0 { stack.append(.interpolation(depth: next)) }
                    index += 1
                } else {
                    index += 1
                }
            case .string(let multiline, let count):
                let byte = bytes[index]
                let start = index
                defer {
                    // The text just passed over, not the closing quote or an interpolation's `\(`.
                    if strings, case .string = stack.last, index > start { blank(start..<index) }
                }
                if byte == newline, !multiline {
                    stack.removeLast()
                    index += 1
                } else if byte == backslash, pounds(from: index + 1) >= count {
                    let after = index + 1 + count
                    if at(after, is: UInt8(ascii: "(")) {
                        stack.append(.interpolation(depth: 1))
                        index = after + 1
                    } else {
                        // An escape: skip the escaped character (a newline still ends the line).
                        index = at(after, is: newline) ? after : after + 1
                    }
                } else if byte == quote, !multiline || isTripleQuote(index) {
                    let end = index + (multiline ? 3 : 1)
                    if pounds(from: end) >= count {
                        stack.removeLast()
                        index = end + count
                    } else {
                        index += 1
                    }
                } else {
                    index += 1
                }
            }
        }
        return bytes
    }
}
