import Foundation

/// An entry in an EPUB's table of contents, as the reader page sends it in a `toc` event.
public struct EPUBTOCItem: Sendable, Hashable, Decodable {
    public var id: String
    public var label: String
    /// The spine href, which `EPUBBridgeCommand.display(target:)` accepts.
    public var href: String
    public var subitems: [EPUBTOCItem]

    public init(id: String, label: String, href: String, subitems: [EPUBTOCItem] = []) {
        self.id = id
        self.label = label
        self.href = href
        self.subitems = subitems
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, href, subitems
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        href = try container.decode(String.self, forKey: .href)
        // A leaf may leave `subitems` out.
        subitems = try container.decodeIfPresent([EPUBTOCItem].self, forKey: .subitems) ?? []
    }
}

/// The location the reader page reports after it turns a page (a `relocated` event).
public struct EPUBRelocation: Sendable, Hashable, Decodable {
    /// `location.start.cfi`: what is saved as `ebookLocation`.
    public var startCfi: String
    public var endCfi: String
    /// `location.end.percentage`, clamped to 0...1: what is saved as `ebookProgress`.
    public var progress: Double
    public var href: String?
    public var atStart: Bool
    public var atEnd: Bool

    public init(
        startCfi: String, endCfi: String, progress: Double, href: String? = nil, atStart: Bool = false,
        atEnd: Bool = false
    ) {
        self.startCfi = startCfi
        self.endCfi = endCfi
        self.progress = progress.clampedToUnit
        self.href = href
        self.atStart = atStart
        self.atEnd = atEnd
    }

    private enum CodingKeys: String, CodingKey {
        case startCfi, endCfi, progress, href, atStart, atEnd
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            startCfi: try container.decode(String.self, forKey: .startCfi),
            endCfi: try container.decode(String.self, forKey: .endCfi),
            progress: try container.decode(Double.self, forKey: .progress),
            href: try container.decodeIfPresent(String.self, forKey: .href),
            atStart: try container.decode(Bool.self, forKey: .atStart),
            atEnd: try container.decode(Bool.self, forKey: .atEnd))
    }
}

/// Why a message from the reader page couldn't be decoded.
public enum EPUBBridgeDecodingError: Error, Sendable, Equatable {
    /// The message isn't a JSON object.
    case notAnObject
    /// The object has no string `type`.
    case missingType
    /// A field the contract requires for `type` is missing or null. `field` is its path, such as
    /// `progress` or `items.0.label`.
    case missingField(type: String, field: String)
    /// A field has the wrong JSON type.
    case invalidField(type: String, field: String)
}

/// A message from the EPUB reader page (JS → Swift), per the bridge contract and ADR 0008 §1.
///
/// The app's script message handler turns the message body into JSON `Data` and passes it to
/// ``decode(_:)``.
public enum EPUBBridgeEvent: Sendable, Equatable {
    /// The page and bridge script loaded; `window.absReader` exists.
    case ready
    case toc([EPUBTOCItem])
    /// The raw `book.locations.save()` JSON string, to keep in ``EPUBLocationsCache``.
    case locationsReady(String)
    case relocated(EPUBRelocation)
    /// A tap, as fractions of the viewport, clamped to 0...1.
    case tap(x: Double, y: Double)
    /// `phase` is where it failed, for example `"open"`, `"locations"` or `"display"`.
    case error(message: String, phase: String?)
    /// A `type` this version doesn't know; ignore it.
    case unknown(String)

    /// Decodes one message. Unknown types decode to ``unknown(_:)``. Optional fields (`href`,
    /// `phase`, a TOC entry's `subitems`) may be missing, and extra fields are ignored.
    public static func decode(_ data: Data) throws(EPUBBridgeDecodingError) -> EPUBBridgeEvent {
        let decoder = JSONDecoder()
        let type: String
        do {
            type = try decoder.decode(Envelope.self, from: data).type
        } catch DecodingError.dataCorrupted {
            throw .notAnObject
        } catch DecodingError.typeMismatch(_, let context) where context.codingPath.isEmpty {
            throw .notAnObject
        } catch DecodingError.valueNotFound(_, let context) where context.codingPath.isEmpty {
            throw .notAnObject
        } catch {
            throw .missingType
        }
        do {
            switch type {
            case "ready":
                return .ready
            case "toc":
                return .toc(try decoder.decode(TOC.self, from: data).items)
            case "locationsReady":
                return .locationsReady(try decoder.decode(LocationsReady.self, from: data).locations)
            case "relocated":
                return .relocated(try decoder.decode(EPUBRelocation.self, from: data))
            case "tap":
                let tap = try decoder.decode(Tap.self, from: data)
                return .tap(x: tap.x.clampedToUnit, y: tap.y.clampedToUnit)
            case "error":
                let error = try decoder.decode(ErrorMessage.self, from: data)
                return .error(message: error.message, phase: error.phase)
            default:
                return .unknown(type)
            }
        } catch let error as DecodingError {
            throw mapped(error, type: type)
        } catch {
            throw .invalidField(type: type, field: "")
        }
    }

    private static func mapped(_ error: DecodingError, type: String) -> EPUBBridgeDecodingError {
        switch error {
        case .keyNotFound(let key, let context):
            .missingField(type: type, field: path(context.codingPath + [key]))
        case .valueNotFound(_, let context):
            .missingField(type: type, field: path(context.codingPath))
        case .typeMismatch(_, let context), .dataCorrupted(let context):
            .invalidField(type: type, field: path(context.codingPath))
        @unknown default:
            .invalidField(type: type, field: "")
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        keys.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }

    private struct Envelope: Decodable {
        var type: String
    }

    private struct TOC: Decodable {
        var items: [EPUBTOCItem]
    }

    private struct LocationsReady: Decodable {
        var locations: String
    }

    private struct Tap: Decodable {
        var x: Double
        var y: Double
    }

    private struct ErrorMessage: Decodable {
        var message: String
        var phase: String?
    }
}

extension Double {
    fileprivate var clampedToUnit: Double { min(max(self, 0), 1) }
}
