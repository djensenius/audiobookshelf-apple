import Foundation

/// The reader settings sent with `open` and `applySettings`: a JSON object, encoded by the caller.
///
/// The bridge doesn't define the settings model (`ReaderSettingsPayload` in the bridge contract,
/// #104a); it carries the encoded object as is, so the two don't depend on each other.
public struct EPUBSettingsJSON: Sendable, Hashable {
    /// The JSON object's bytes.
    public let data: Data

    /// Encodes `payload`, which must encode to a JSON object.
    public init(encoding payload: some Encodable) throws(EPUBBridgeCommandError) {
        let data: Data
        do {
            data = try JSONEncoder().encode(payload)
        } catch {
            throw .settingsNotAnObject
        }
        try self.init(jsonObject: data)
    }

    /// Wraps JSON that is already encoded; it must be an object.
    public init(jsonObject data: Data) throws(EPUBBridgeCommandError) {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw .settingsNotAnObject }
        self.data = data
    }

    fileprivate var object: Any {
        // `init` checked that it parses.
        (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
    }
}

public enum EPUBBridgeCommandError: Error, Sendable, Equatable {
    /// The settings didn't encode to a JSON object.
    case settingsNotAnObject
}

/// A command to the EPUB reader page (Swift → JS), per the bridge contract and ADR 0008 §1.
///
/// The app passes ``jsonData()`` as an object to `window.absReader.handle(command)`.
public enum EPUBBridgeCommand: Sendable, Hashable {
    /// Opens a book. `url` is an `absreader://book/…` URL. `location` is a CFI already checked to
    /// start with `epubcfi`, or `nil` for the start. `locations` is a cached
    /// `book.locations.save()` string, or `nil` to generate them.
    case open(url: URL, location: String?, locations: String?, settings: EPUBSettingsJSON)
    /// Shows a CFI or a spine href.
    case display(target: String)
    case next
    case prev
    case applySettings(EPUBSettingsJSON)

    /// The command as a JSON object with a `type` and the contract's fields. A `nil` `location` or
    /// `locations` is left out.
    public func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private var jsonObject: [String: Any] {
        switch self {
        case .open(let url, let location, let locations, let settings):
            var object: [String: Any] = ["type": "open", "url": url.absoluteString, "settings": settings.object]
            object["location"] = location
            object["locations"] = locations
            return object
        case .display(let target):
            return ["type": "display", "target": target]
        case .next:
            return ["type": "next"]
        case .prev:
            return ["type": "prev"]
        case .applySettings(let settings):
            return ["type": "applySettings", "settings": settings.object]
        }
    }
}

extension EPUBBridgeCommand {
    /// The tap zone at each side of the page, as a fraction of the viewport's width: a tap nearer
    /// the edge turns the page, one between them shows or hides the chrome.
    public static let pageTurnZone = 0.25

    /// The page turn for the arrow key pointing at `edge`: toward the next page on the book's
    /// reading side. epub.js lays a right-to-left book's pages (`page-progression-direction="rtl"`)
    /// from right to left, so there the left arrow goes forward. It's the book's direction, not the
    /// app's language, as in the comic reader (``ComicReaderLayout/step(for:rightToLeft:)``).
    public static func pageTurn(toward edge: ComicReaderLayout.Arrow, rightToLeft: Bool) -> EPUBBridgeCommand {
        ComicReaderLayout.step(for: edge, rightToLeft: rightToLeft) > 0 ? .next : .prev
    }

    /// The page turn for a tap `x` of the way across the viewport (from its left edge, 0...1), or
    /// `nil` for a tap in the middle, which shows or hides the chrome. The edges follow the book's
    /// direction, as ``pageTurn(toward:rightToLeft:)``.
    public static func pageTurn(forTapAt x: Double, rightToLeft: Bool) -> EPUBBridgeCommand? {
        if x < pageTurnZone { return pageTurn(toward: .left, rightToLeft: rightToLeft) }
        if x > 1 - pageTurnZone { return pageTurn(toward: .right, rightToLeft: rightToLeft) }
        return nil
    }
}
