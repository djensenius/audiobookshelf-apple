import Foundation

/// Links times such as `12:34` and `1:02:03` in episode show notes to an internal
/// `abs-timestamp:` URL, so the episode screen can play from that time (legacy
/// `pages/item/_id/_episode/index.vue` `timeMarkerRegex`).
///
/// A time must stand alone: it isn't linked inside a word, a number, a path or an existing
/// link. Minutes and seconds after the first part must be two digits below 60, and when the
/// episode's duration is known the time must not be past its end.
public enum ShowNotesTimestamps {
    /// The URL scheme of the links, which only the episode screen handles.
    public static let scheme = "abs-timestamp"

    // Not after or before a letter, digit, `_`, `:` or `/`; not after `.`, `#` or `=` either.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}\p{M}_:/.#=])([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?(?![\p{L}\p{N}\p{M}_:/])"#)

    /// `text` with each standalone time within `duration` (any time when it's `nil` or not
    /// positive) linked to ``url(seconds:)``. Text that's already a link is left alone.
    public static func link(_ text: AttributedString, duration: Double?) -> AttributedString {
        var result = text
        for (range, seconds) in matches(in: String(text.characters), duration: duration) {
            guard let attributed = Range<AttributedString.Index>(range, in: result),
                !result[attributed].runs.contains(where: { $0.link != nil })
            else { continue }
            result[attributed].link = url(seconds: seconds)
        }
        return result
    }

    /// The link that plays from `seconds`.
    public static func url(seconds: Int) -> URL {
        URL(string: "\(scheme):\(seconds)")!
    }

    /// The time `url` plays from, or `nil` if it isn't a valid timestamp link.
    public static func seconds(in url: URL) -> Int? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let value = url.absoluteString.dropFirst(scheme.count + 1)
        guard !value.isEmpty, value.allSatisfy(\.isASCII), let seconds = Int(value), seconds >= 0 else { return nil }
        return seconds
    }

    /// Each standalone, in-range time in `string`: its UTF-16 range and its value in seconds.
    static func matches(in string: String, duration: Double?) -> [(NSRange, Int)] {
        let whole = NSRange(string.startIndex..., in: string)
        return pattern.matches(in: string, range: whole).compactMap { match in
            let parts = (1..<match.numberOfRanges).compactMap { index -> Int? in
                let range = match.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: string) else { return nil }
                return Int(string[swiftRange])
            }
            guard parts.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
            let seconds = parts.reduce(0) { $0 * 60 + $1 }
            if let duration, duration > 0, Double(seconds) > duration { return nil }
            return (match.range, seconds)
        }
    }
}
